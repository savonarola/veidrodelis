defmodule Vdr.TSProj do
  @moduledoc """
  TS-based Redis replication stream processor with typed stores.

  This module provides Redis replication stream processing using TS (Rust-based storage)
  for efficient key-value storage. Currently supports string operations only.
  All keys and values are stored as raw binaries.
  """

  require Logger

  @behaviour Vdr.RedisStream.Callback

  alias Vdr.RedisStream.Command
  alias Command, as: RedisCommand

  @tx_key "__vdr_tx"

  defstruct [
    :ts_storage,
    :id,
    :new_ts_storage,
    :ready,
    :tx_buffer,
    :in_transaction,
    :watch,
    :monitors
  ]

  @type key :: binary()
  @type value :: binary()

  @type t :: %__MODULE__{
          ts_storage: reference(),
          id: term(),
          new_ts_storage: reference() | nil,
          ready: boolean(),
          tx_buffer: list(),
          in_transaction: boolean(),
          watch: Vdr.TS.Watch.t(),
          monitors: %{pid() => reference()}
        }

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)

    redis_opts =
      Keyword.take(opts, [
        :host,
        :port,
        :username,
        :password,
        :ssl,
        :ssl_opts,
        :reconnect,
        :reconnect_delay_ms,
        :max_reconnect_delay_ms,
        :command_filter
      ])

    callback_opts = Keyword.get(opts, :callback_opts, [])
    callback_opts = Keyword.put(callback_opts, :id, id)

    callback_module = __MODULE__

    replica_opts =
      [
        callback_module: callback_module,
        callback_opts: callback_opts
      ] ++ redis_opts

    Vdr.RedisStream.Replica.start_link(replica_opts)
  end

  @impl Vdr.RedisStream.Callback
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    state = initialize_state(id)

    # Register instance immediately so it can accept watch requests
    # before streaming starts (ts_storage will be empty until first sync)
    :ok =
      Vdr.Registry.register(self(), state.id, %Vdr.Handle{
        callback_module: __MODULE__,
        handle_state: %{pid: self(), ts_storage: state.ts_storage, ready: false},
        pid: self()
      })

    {:ok, state}
  end

  @impl Vdr.RedisStream.Callback
  def handle_replication_start(state) do
    reinitialize_state(state)
  end

  @impl Vdr.RedisStream.Callback
  def handle_streaming_start(state) do
    # Replace current ts_storage with new_ts_storage
    # Set ready flag to true
    # Clear new_ts_storage
    new_state = %{state | ts_storage: state.new_ts_storage, new_ts_storage: nil, ready: true}

    # Send Init messages to all watchers
    new_state.watch
    |> Vdr.TS.Watch.all_watchers()
    |> Enum.each(fn {pid, ref} ->
      send(pid, {ref, %Vdr.WatchEvent.Init{}})
    end)

    # Update registry with new ts_storage and set ready flag
    :ok =
      Vdr.Registry.register(self(), state.id, %Vdr.Handle{
        callback_module: __MODULE__,
        handle_state: %{pid: self(), ts_storage: new_state.ts_storage, ready: true},
        pid: self()
      })

    {:ok, new_state}
  end

  @impl Vdr.RedisStream.Callback
  def handle_commands(%__MODULE__{} = state, commands) when is_list(commands) do
    new_state = Enum.reduce(commands, state, &process_single_command/2)
    # Flush any remaining buffered commands at the end (only if not in transaction)
    flushed_state =
      if new_state.in_transaction, do: new_state, else: flush_tx_buffer(new_state)

    {:ok, flushed_state}
  end

  # Transaction start: SET __vdr_tx
  defp process_single_command(
         %Vdr.RedisStream.ReplicaCommand{db: db, command: %RedisCommand.Set{key: @tx_key} = cmd},
         %__MODULE__{} = state
       ) do
    # Flush any buffered commands before starting the transaction
    flushed_state = flush_tx_buffer(state)
    # Start transaction and buffer this SET command
    %{flushed_state | in_transaction: true, tx_buffer: [{db, cmd}]}
  end

  # Transaction end: DEL __vdr_tx
  defp process_single_command(
         %Vdr.RedisStream.ReplicaCommand{db: db, command: %RedisCommand.Del{keys: keys} = cmd},
         %__MODULE__{} = state
       ) do
    if @tx_key in keys do
      # Buffer the DEL command, then flush all buffered commands
      state_with_del = %{state | tx_buffer: [{db, cmd} | state.tx_buffer]}
      flushed_state = flush_tx_buffer(state_with_del)
      %{flushed_state | in_transaction: false}
    else
      # Normal DEL command, buffer it
      %{state | tx_buffer: [{db, cmd} | state.tx_buffer]}
    end
  end

  # Buffer the command (prepend for O(1) performance)
  # Commands are flushed at end of handle_commands or when transaction ends
  defp process_single_command(
         %Vdr.RedisStream.ReplicaCommand{db: db, command: command},
         %__MODULE__{} = state
       ) do
    %{state | tx_buffer: [{db, command} | state.tx_buffer]}
  end

  @impl Vdr.RedisStream.Callback
  def handle_call(%__MODULE__{} = state, message) do
    case message do
      # Watch subscription
      {:watch, pid, db, key, ref} ->
        case Vdr.TS.Watch.add(state.watch, pid, db, key, ref) do
          {:ok, new_watch} ->
            # Monitor the process if not already monitored
            new_monitors =
              if Map.has_key?(state.monitors, pid) do
                state.monitors
              else
                monitor_ref = Process.monitor(pid)
                Map.put(state.monitors, pid, monitor_ref)
              end

            new_state = %{state | watch: new_watch, monitors: new_monitors}
            {:reply, :ok, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      # Watch unsubscription
      {:unwatch, pid, db, key} ->
        case Vdr.TS.Watch.delete(state.watch, pid, db, key) do
          {:ok, new_watch, 0} ->
            # Last watch for this pid - demonitor
            case Map.get(state.monitors, pid) do
              nil -> :ok
              monitor_ref -> Process.demonitor(monitor_ref, [:flush])
            end

            new_monitors = Map.delete(state.monitors, pid)
            new_state = %{state | watch: new_watch, monitors: new_monitors}
            {:reply, :ok, new_state}

          {:ok, new_watch, _remaining} ->
            # Pid still has other watches - keep monitoring
            new_state = %{state | watch: new_watch}
            {:reply, :ok, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      # Read operations - check if ready
      {:get, db, key} ->
        if not state.ready do
          {:reply, {:error, :not_ready}, state}
        else
          case Vdr.TS.read_tx(state.ts_storage, db, [{:get, key}]) do
            {:ok, [result]} -> {:reply, {:ok, result}, state}
            {:error, _} = error -> {:reply, error, state}
          end
        end

      _ ->
        {:reply, {:error, :not_implemented}, state}
    end
  end

  @impl Vdr.RedisStream.Callback
  def handle_info(%__MODULE__{} = state, {:DOWN, _ref, :process, pid, _reason}) do
    # Remove all watches for the crashed process
    new_watch = Vdr.TS.Watch.delete_all(state.watch, pid)
    new_monitors = Map.delete(state.monitors, pid)
    new_state = %{state | watch: new_watch, monitors: new_monitors}
    {:noreply, new_state}
  end

  def handle_info(%__MODULE__{} = state, _message) do
    # Ignore other messages
    {:noreply, state}
  end

  @impl Vdr.RedisStream.Callback
  def handle_destroy(%__MODULE__{ts_storage: ts_storage, new_ts_storage: new_ts_storage}) do
    # Clean up TS storage
    if ts_storage, do: Vdr.TS.destroy(ts_storage)
    if new_ts_storage, do: Vdr.TS.destroy(new_ts_storage)
    :ok
  end

  def handle_destroy(_state) do
    :ok
  end

  # Private functions

  defp initialize_state(id) do
    %__MODULE__{
      id: id,
      ts_storage: Vdr.TS.create(),
      new_ts_storage: nil,
      ready: false,
      tx_buffer: [],
      in_transaction: false,
      watch: Vdr.TS.Watch.create(),
      monitors: %{}
    }
  end

  defp reinitialize_state(%__MODULE__{} = state) do
    # Create new_ts_storage for incoming RDB data
    # Keep current ts_storage for serving reads during RDB transfer
    # Keep ready flag as-is (true after first sync, false initially)
    # Clear any ongoing transaction on reconnection
    new_state = %{state | new_ts_storage: Vdr.TS.create(), tx_buffer: [], in_transaction: false}

    # Registry is already registered in init, no need to re-register
    {:ok, new_state}
  end

  @doc """
  Executes multiple read-only commands atomically under a single mutex lock.

  Commands are executed in order and their results are returned as a list.
  Only read-only commands are allowed; write commands will return `{:error, :readonly_violation}`.

  ## Parameters

    * `handle_state` - The handle state map with `:ready` and `:ts_storage` keys
    * `db` - Database number
    * `commands` - List of read command tuples

  ## Supported Commands

    * `{:get, key}` - Get string value
    * `{:hget, key, field}` - Get hash field value
    * `{:hmget, key, fields}` - Get multiple hash field values
    * `{:hgetall, key}` - Get all hash fields and values
    * `{:hkeys, key}` - Get hash field names
    * `{:hvals, key}` - Get hash values
    * `{:hlen, key}` - Get hash length
    * `{:llen, key}` - Get list length
    * `{:lrange, key, start, stop}` - Get list range
    * `{:smembers, key}` - Get set members
    * `{:sismember, key, member}` - Check set membership
    * `{:scard, key}` - Get set cardinality
    * `{:zscore, key, member}` - Get sorted set member score
    * `{:zcard, key}` - Get sorted set cardinality
    * `{:zrange, key, start, stop, with_scores}` - Get sorted set range
    * `{:zrangebyscore, key, min, max, with_scores}` - Get sorted set range by score
    * `{:zrank, key, member}` - Get sorted set member rank
    * `{:zrevrank, key, member}` - Get sorted set member reverse rank
    * `{:zcount, key, min, max}` - Count sorted set members in score range

  ## Returns

    * `{:ok, results}` - List of results in same order as commands
    * `{:error, :not_ready}` - Instance not ready
    * `{:error, :readonly_violation}` - Write command detected

  ## Examples

      handle_state = %{ts_storage: storage, ready: true}
      {:ok, [value1, value2]} = Vdr.TSProj.read_tx(handle_state, 0, [
        {:get, "key1"},
        {:hget, "hash1", "field1"}
      ])
  """
  @spec read_tx(%{ts_storage: reference(), ready: boolean()}, non_neg_integer(), [tuple()]) ::
          {:ok, [term()]} | {:error, term()}
  def read_tx(%{ready: ready, ts_storage: ts_storage}, db, commands) when is_list(commands) do
    if ready do
      Vdr.TS.read_tx(ts_storage, db, commands)
    else
      {:error, :not_ready}
    end
  end

  @doc """
  Executes a Lua script with access to ts.get and ts.hget functions.

  The script is executed atomically under the storage mutex and has access to:
  - `ts.get(key)` - Get a string value
  - `ts.hget(key, field)` - Get a hash field value

  Returns `{:ok, result}` where result is the script's return value as a binary,
  or `{:error, reason}` if the script fails.

  ## Examples

      handle_state = %{ts_storage: storage}
      script = "return ts.get('key1')"
      {:ok, result} = Vdr.TSProj.tx(handle_state, 0, script)
  """
  @spec tx(%{ts_storage: reference(), ready: boolean()}, non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def tx(%{ready: ready, ts_storage: ts_storage}, db, script) when is_binary(script) do
    if ready do
      Vdr.TS.read_tx(ts_storage, db, script)
    else
      {:error, :not_ready}
    end
  end

  @doc """
  Compiles a Lua script to bytecode for faster execution.

  The compiled bytecode can be passed to `tx/3` instead of a script string.
  """
  @spec lua_load(%{ts_storage: reference()}, binary()) :: {:ok, binary()} | {:error, term()}
  def lua_load(%{ts_storage: ts_storage}, script) when is_binary(script) do
    Vdr.TS.lua_load(ts_storage, script)
  end

  # Convert RedisCommand to tuple format for NIF
  defp convert_command(db, %RedisCommand.Set{key: key, value: value}) do
    {db, {:set, key, value}}
  end

  defp convert_command(db, %RedisCommand.Del{keys: keys}) do
    {db, {:del, keys}}
  end

  defp convert_command(db, %RedisCommand.Unlink{keys: keys}) do
    # UNLINK is semantically equivalent to DEL for our purposes
    {db, {:del, keys}}
  end

  defp convert_command(db, %RedisCommand.Copy{
         source: source,
         destination: destination,
         replace: replace
       }) do
    {db, {:copy, source, destination, replace}}
  end

  defp convert_command(db, %RedisCommand.SAdd{key: key, members: members}) do
    {db, {:sadd, key, members}}
  end

  defp convert_command(db, %RedisCommand.SRem{key: key, members: members}) do
    {db, {:srem, key, members}}
  end

  defp convert_command(db, %RedisCommand.SMove{
         source: source_key,
         destination: dest_key,
         member: member
       }) do
    {db, {:smove, source_key, dest_key, member}}
  end

  defp convert_command(db, %RedisCommand.SUnionStore{destination: dest_key, keys: source_keys}) do
    {db, {:sunionstore, dest_key, source_keys}}
  end

  defp convert_command(db, %RedisCommand.SInterStore{destination: dest_key, keys: source_keys}) do
    {db, {:sinterstore, dest_key, source_keys}}
  end

  defp convert_command(db, %RedisCommand.SDiffStore{destination: dest_key, keys: source_keys}) do
    {db, {:sdiffstore, dest_key, source_keys}}
  end

  defp convert_command(db, %RedisCommand.LPush{key: key, values: values}) do
    {db, {:lpush, key, values}}
  end

  defp convert_command(db, %RedisCommand.RPush{key: key, values: values}) do
    {db, {:rpush, key, values}}
  end

  defp convert_command(db, %RedisCommand.LPushX{key: key, values: values}) do
    {db, {:lpushx, key, values}}
  end

  defp convert_command(db, %RedisCommand.RPushX{key: key, values: values}) do
    {db, {:rpushx, key, values}}
  end

  defp convert_command(db, %RedisCommand.LPop{key: key, count: nil}) do
    {db, {:lpop, key}}
  end

  defp convert_command(db, %RedisCommand.LPop{key: key, count: count}) do
    {db, {:lpop_count, key, count}}
  end

  defp convert_command(db, %RedisCommand.RPop{key: key, count: nil}) do
    {db, {:rpop, key}}
  end

  defp convert_command(db, %RedisCommand.RPop{key: key, count: count}) do
    {db, {:rpop_count, key, count}}
  end

  defp convert_command(db, %RedisCommand.LSet{key: key, index: index, value: value}) do
    {db, {:lset, key, index, value}}
  end

  defp convert_command(db, %RedisCommand.RPopLPush{source: source_key, destination: dest_key}) do
    {db, {:rpoplpush, source_key, dest_key}}
  end

  defp convert_command(db, %RedisCommand.LMove{
         source: source_key,
         destination: dest_key,
         wherefrom: wherefrom,
         whereto: whereto
       }) do
    {db, {:lmove, source_key, dest_key, wherefrom, whereto}}
  end

  defp convert_command(db, %RedisCommand.HSet{key: key, fields: fields}) do
    {db, {:hmset, key, fields}}
  end

  defp convert_command(db, %RedisCommand.HDel{key: key, fields: fields}) do
    {db, {:hdel, key, fields}}
  end

  defp convert_command(db, %RedisCommand.HMSet{key: key, fields: fields}) do
    {db, {:hmset, key, fields}}
  end

  defp convert_command(db, %RedisCommand.HSetNX{key: key, field: field, value: value}) do
    {db, {:hsetnx, key, field, value}}
  end

  defp convert_command(db, %RedisCommand.HIncrBy{key: key, field: field, increment: increment}) do
    {db, {:hincrby, key, field, increment}}
  end

  defp convert_command(db, %RedisCommand.HIncrByFloat{
         key: key,
         field: field,
         increment: increment
       }) do
    {db, {:hincrbyfloat, key, field, increment}}
  end

  defp convert_command(db, %RedisCommand.HSetEX{
         key: key,
         nx_xx_option: nx_xx_option,
         fields: fields
       }) do
    {db, {:hsetex, key, nx_xx_option, fields}}
  end

  defp convert_command(db, %RedisCommand.ZAdd{key: key, members: members, options: options}) do
    {db, {:zadd, key, members, options}}
  end

  defp convert_command(db, %RedisCommand.ZIncrBy{key: key, increment: increment, member: member}) do
    {db, {:zincrby, key, increment, member}}
  end

  defp convert_command(db, %RedisCommand.ZRem{key: key, members: members}) do
    {db, {:zrem, key, members}}
  end

  defp convert_command(db, %RedisCommand.MSet{pairs: pairs}) do
    {db, {:mset, pairs}}
  end

  defp convert_command(db, %RedisCommand.Append{key: key, value: value}) do
    {db, {:append, key, value}}
  end

  defp convert_command(db, %RedisCommand.SetRange{key: key, offset: offset, value: value}) do
    {db, {:setrange, key, offset, value}}
  end

  defp convert_command(db, %RedisCommand.Incr{key: key}) do
    {db, {:incr, key}}
  end

  defp convert_command(db, %RedisCommand.IncrBy{key: key, increment: increment}) do
    {db, {:incrby, key, increment}}
  end

  defp convert_command(db, %RedisCommand.Decr{key: key}) do
    {db, {:decr, key}}
  end

  defp convert_command(db, %RedisCommand.DecrBy{key: key, decrement: decrement}) do
    {db, {:decrby, key, decrement}}
  end

  defp convert_command(db, %RedisCommand.SetNX{key: key, value: value}) do
    {db, {:setnx, key, value}}
  end

  defp convert_command(db, %RedisCommand.MSetNX{pairs: pairs}) do
    {db, {:msetnx, pairs}}
  end

  defp convert_command(db, %RedisCommand.GetSet{key: key, value: value}) do
    {db, {:getset, key, value}}
  end

  defp convert_command(db, %RedisCommand.GetDel{key: key}) do
    {db, {:getdel, key}}
  end

  defp convert_command(db, %RedisCommand.Rename{key: old_key, newkey: new_key}) do
    {db, {:rename, old_key, new_key}}
  end

  defp convert_command(db, %RedisCommand.RenameNX{key: old_key, newkey: new_key}) do
    {db, {:renamenx, old_key, new_key}}
  end

  defp convert_command(db, %RedisCommand.Move{key: key, db: target_db}) do
    {db, {:move_key, key, target_db}}
  end

  defp convert_command(db, %RedisCommand.Persist{key: key}) do
    {db, {:persist, key}}
  end

  defp convert_command(db, %RedisCommand.PExpireAt{key: key, timestamp_ms: timestamp_ms}) do
    {db, {:pexpireat, key, timestamp_ms}}
  end

  defp convert_command(db, %RedisCommand.LRem{key: key, count: count, value: value}) do
    {db, {:lrem, key, count, value}}
  end

  defp convert_command(db, %RedisCommand.LTrim{key: key, start: start, stop: stop}) do
    {db, {:ltrim, key, start, stop}}
  end

  defp convert_command(db, %RedisCommand.LInsert{
         key: key,
         before_after: before_after,
         pivot: pivot,
         element: element
       }) do
    {db, {:linsert, key, before_after, pivot, element}}
  end

  defp convert_command(db, %RedisCommand.ZPopMax{key: key, count: count}) do
    {db, {:zpopmax, key, count}}
  end

  defp convert_command(db, %RedisCommand.ZPopMin{key: key, count: count}) do
    {db, {:zpopmin, key, count}}
  end

  defp convert_command(db, %RedisCommand.ZRemRangeByRank{key: key, start: start, stop: stop}) do
    {db, {:zremrangebyrank, key, start, stop}}
  end

  defp convert_command(db, %RedisCommand.ZRemRangeByScore{key: key, min: min_str, max: max_str}) do
    # Parse min and max as floats (they come as strings from Redis)
    # Handle exclusive ranges like "(1.0" - the "(" prefix indicates exclusivity
    # Convert to Bound tuples: :unbounded | {:included, score} | {:excluded, score}
    min_bound = parse_score_bound(min_str)
    max_bound = parse_score_bound(max_str)
    {db, {:zremrangebyscore, key, min_bound, max_bound}}
  end

  defp convert_command(db, %RedisCommand.ZRemRangeByLex{key: key, min: min_str, max: max_str}) do
    # Parse lexicographic bounds
    # Syntax: - (min unbounded), + (max unbounded), [value (inclusive), (value (exclusive)
    min_bound = parse_lex_bound(min_str)
    max_bound = parse_lex_bound(max_str)
    {db, {:zremrangebylex, key, min_bound, max_bound}}
  end

  defp convert_command(db, %RedisCommand.ZUnionStore{
         destination: dest_key,
         keys: source_keys,
         weights: weights,
         aggregate: aggregate
       }) do
    # Default weights to 1.0 for each key if not provided
    weights_list = weights || Enum.map(source_keys, fn _ -> 1.0 end)
    # Default aggregate to :sum if not provided
    aggregate_atom = aggregate || :sum
    {db, {:zunionstore, dest_key, source_keys, weights_list, aggregate_atom}}
  end

  defp convert_command(db, %RedisCommand.ZInterStore{
         destination: dest_key,
         keys: source_keys,
         weights: weights,
         aggregate: aggregate
       }) do
    # Default weights to 1.0 for each key if not provided
    weights_list = weights || Enum.map(source_keys, fn _ -> 1.0 end)
    # Default aggregate to :sum if not provided
    aggregate_atom = aggregate || :sum
    {db, {:zinterstore, dest_key, source_keys, weights_list, aggregate_atom}}
  end

  defp convert_command(db, %RedisCommand.ZDiffStore{
         destination: dest_key,
         keys: source_keys
       }) do
    {db, {:zdiffstore, dest_key, source_keys}}
  end

  defp convert_command(db, %RedisCommand.ZRangeStore{
         destination: dest_key,
         source: source_key,
         min: min_str,
         max: max_str,
         options: options
       }) do
    # ZRANGESTORE supports BYSCORE, BYLEX, REV, and LIMIT options
    # Pass min/max as strings so Rust can parse them based on the mode
    # Convert options list to uppercase strings
    opts = (options || []) |> Enum.map(&String.upcase/1)
    {db, {:zrangestore, dest_key, source_key, min_str, max_str, opts}}
  end

  # Server commands
  defp convert_command(_db, %RedisCommand.FlushAll{}) do
    # db is ignored - flushall clears all databases
    {0, {:flushall}}
  end

  defp convert_command(db, %RedisCommand.FlushDB{}) do
    # Clear the specific database
    {db, {:flushdb}}
  end

  defp convert_command(_db, %RedisCommand.SwapDB{db1: db1, db2: db2}) do
    # db is ignored - swapdb uses explicit db1 and db2
    {0, {:swapdb, db1, db2}}
  end

  # Ignore all other commands
  defp convert_command(_db, _command) do
    nil
  end

  # Helper to parse score strings to floats (handles "-inf", "+inf", etc.)
  defp parse_score_to_float(str) when is_binary(str) do
    case str do
      "-inf" ->
        :neg_infinity

      "+inf" ->
        :infinity

      "inf" ->
        :infinity

      str ->
        case Float.parse(str) do
          {float, _} -> float
          :error -> String.to_integer(str) * 1.0
        end
    end
  end

  # Parse score bound from string to Bound tuple
  # Returns: :unbounded | {:included, score} | {:excluded, score}
  defp parse_score_bound(str) do
    cond do
      # Check for exclusive prefix "("
      String.starts_with?(str, "(") ->
        score_str = String.slice(str, 1..-1//1)
        score = parse_score_to_float(score_str)
        {:excluded, score}

      # Otherwise inclusive
      true ->
        score = parse_score_to_float(str)

        if score == :neg_infinity or score == :infinity do
          :unbounded
        else
          {:included, score}
        end
    end
  end

  # Parse lexicographic bound from string to Bound tuple
  # Returns: :unbounded | {:included, value} | {:excluded, value}
  # Syntax: - (unbounded min), + (unbounded max), [value (inclusive), (value (exclusive)
  defp parse_lex_bound(str) do
    cond do
      str == "-" or str == "+" ->
        :unbounded

      String.starts_with?(str, "[") ->
        value = String.slice(str, 1..-1//1)
        {:included, value}

      String.starts_with?(str, "(") ->
        value = String.slice(str, 1..-1//1)
        {:excluded, value}

      # Default to inclusive if no prefix
      true ->
        {:included, str}
    end
  end

  # Transaction helper functions

  # Flush buffered commands: execute all in single tx, notify watchers, clear buffer
  defp flush_tx_buffer(%__MODULE__{tx_buffer: []} = state), do: state

  defp flush_tx_buffer(%__MODULE__{tx_buffer: buffer} = state) do
    # Reverse the buffer since we prepended commands
    commands = Enum.reverse(buffer)

    # Determine which storage to write to
    ts_storage =
      if state.new_ts_storage do
        state.new_ts_storage
      else
        state.ts_storage
      end

    # Convert all commands to tuple format, filtering out unsupported ones
    cmd_tuples =
      commands
      |> Enum.map(fn {db, command} -> convert_command(db, command) end)
      |> Enum.reject(&is_nil/1)

    # Execute all commands in a single tx call
    if cmd_tuples != [] do
      Vdr.TS.tx(ts_storage, cmd_tuples)
    end

    # Notify watchers for each command (in order)
    Enum.each(commands, fn {db, cmd} ->
      notify_watchers(state, db, cmd)
    end)

    %{state | tx_buffer: []}
  end

  # Extract all keys affected by a command for watch notifications
  defp extract_affected_keys(command) do
    case command do
      # Multiple keys
      %RedisCommand.Del{keys: keys} ->
        keys

      %RedisCommand.MSet{pairs: pairs} ->
        Enum.map(pairs, fn {k, _v} -> k end)

      # Source/destination commands (must come before single key pattern)
      %RedisCommand.RPopLPush{source: src, destination: dest} ->
        [src, dest]

      %RedisCommand.LMove{source: src, destination: dest} ->
        [src, dest]

      %RedisCommand.Rename{key: old_key, newkey: new_key} ->
        [old_key, new_key]

      %RedisCommand.RenameNX{key: old_key, newkey: new_key} ->
        [old_key, new_key]

      %RedisCommand.SMove{source: src, destination: dest} ->
        [src, dest]

      # Store commands (affect destination + sources)
      %RedisCommand.SUnionStore{destination: dest, keys: keys} ->
        [dest | keys]

      %RedisCommand.SInterStore{destination: dest, keys: keys} ->
        [dest | keys]

      %RedisCommand.SDiffStore{destination: dest, keys: keys} ->
        [dest | keys]

      %RedisCommand.ZUnionStore{destination: dest, keys: keys} ->
        [dest | keys]

      %RedisCommand.ZInterStore{destination: dest, keys: keys} ->
        [dest | keys]

      %RedisCommand.ZDiffStore{destination: dest, keys: keys} ->
        [dest | keys]

      %RedisCommand.ZRangeStore{destination: dest, source: src} ->
        [dest, src]

      # Single key commands (must come after multi-key patterns)
      %{key: key} when is_binary(key) ->
        [key]

      # Catch-all for commands we don't track
      _ ->
        []
    end
  end

  # Notify all watchers of a command
  defp notify_watchers(state, db, command) do
    # Only notify in streaming mode (not during RDB transfer)
    if state.ready do
      case command do
        # FLUSHALL affects all databases - notify all watchers
        %RedisCommand.FlushAll{} ->
          state.watch
          |> Vdr.TS.Watch.all_watchers()
          |> Enum.each(fn {pid, ref} ->
            send(pid, {ref, %Vdr.WatchEvent.Update{command: command, db: db}})
          end)

        # FLUSHDB affects a specific database - notify all watchers in that db
        %RedisCommand.FlushDB{} ->
          state.watch
          |> Vdr.TS.Watch.lookup_by_db(db)
          |> Enum.each(fn {ref, pid} ->
            send(pid, {ref, %Vdr.WatchEvent.Update{command: command, db: db}})
          end)

        # SWAPDB affects two databases - notify watchers in both
        %RedisCommand.SwapDB{db1: db1, db2: db2} ->
          db1_watchers = Vdr.TS.Watch.lookup_by_db(state.watch, db1)
          db2_watchers = Vdr.TS.Watch.lookup_by_db(state.watch, db2)

          # Combine and deduplicate watchers
          all_watchers = Enum.uniq(db1_watchers ++ db2_watchers)

          Enum.each(all_watchers, fn {ref, pid} ->
            send(pid, {ref, %Vdr.WatchEvent.Update{command: command, db: db}})
          end)

        # Regular key-based commands
        _ ->
          keys = extract_affected_keys(command)

          Enum.each(keys, fn key ->
            state.watch
            |> Vdr.TS.Watch.lookup(db, key)
            |> Enum.each(fn {ref, pid} ->
              send(pid, {ref, %Vdr.WatchEvent.Update{command: command, db: db}})
            end)
          end)
      end
    end

    :ok
  end
end
