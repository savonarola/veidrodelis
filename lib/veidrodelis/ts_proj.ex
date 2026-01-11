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

  defstruct [:ts_storage, :id, :new_ts_storage, :ready, :tx_buffer, :in_transaction]

  @type key :: binary()
  @type value :: binary()

  @type t :: %__MODULE__{
          ts_storage: reference(),
          id: term(),
          new_ts_storage: reference() | nil,
          ready: boolean(),
          tx_buffer: list(),
          in_transaction: boolean()
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

    # Register with both pid and TS storage in handle_state
    :ok =
      Vdr.Registry.register(self(), id, %Vdr.Handle{
        callback_module: __MODULE__,
        handle_state: %{pid: self(), ts_storage: state.ts_storage},
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

    # Update registry with new ts_storage
    :ok =
      Vdr.Registry.register(self(), state.id, %Vdr.Handle{
        callback_module: __MODULE__,
        handle_state: %{pid: self(), ts_storage: new_state.ts_storage},
        pid: self()
      })

    {:ok, new_state}
  end

  @impl Vdr.RedisStream.Callback
  # Transaction start: SET __vdr_tx
  def handle_command(
        %__MODULE__{} = state,
        %Vdr.RedisStream.ReplicaCommand{db: db, command: %RedisCommand.Set{key: @tx_key} = cmd}
      ) do
    # Start transaction and buffer this SET command
    {:ok, %{state | in_transaction: true, tx_buffer: [{db, cmd}]}}
  end

  # Transaction end: DEL __vdr_tx
  def handle_command(
        %__MODULE__{} = state,
        %Vdr.RedisStream.ReplicaCommand{db: db, command: %RedisCommand.Del{keys: keys} = cmd}
      ) do
    if @tx_key in keys do
      # Buffer the DEL command, then apply all buffered commands
      state_with_del = %{state | tx_buffer: [{db, cmd} | state.tx_buffer]}
      new_state = apply_transaction(state_with_del)
      {:ok, %{new_state | in_transaction: false, tx_buffer: []}}
    else
      # Normal DEL command, buffer if in transaction
      if state.in_transaction do
        {:ok, %{state | tx_buffer: [{db, cmd} | state.tx_buffer]}}
      else
        execute_command(state, db, cmd)
        {:ok, state}
      end
    end
  end

  # In transaction: buffer the command (prepend for O(1) performance)
  def handle_command(
        %__MODULE__{in_transaction: true} = state,
        %Vdr.RedisStream.ReplicaCommand{db: db, command: command}
      ) do
    {:ok, %{state | tx_buffer: [{db, command} | state.tx_buffer]}}
  end

  # Normal command processing
  def handle_command(%__MODULE__{} = state, %Vdr.RedisStream.ReplicaCommand{
        db: db,
        command: command
      }) do
    execute_command(state, db, command)
    {:ok, state}
  end

  @impl Vdr.RedisStream.Callback
  def handle_call(%__MODULE__{} = state, message) do
    # Check if ready to serve reads
    if not state.ready do
      {:reply, {:error, :not_ready}, state}
    else
      # Serve reads from current ts_storage (not new_ts_storage)
      case message do
        {:get, db, key} ->
          result = Vdr.TS.get(state.ts_storage, db, key)
          {:reply, {:ok, result}, state}

        _ ->
          {:reply, {:error, :not_implemented}, state}
      end
    end
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
      in_transaction: false
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

  # Public accessor functions
  # Uses TS storage directly instead of GenServer calls
  # Only get/3 is implemented, all others return {:error, :not_implemented}

  def get(handle_state, db, key) when is_map(handle_state) and is_binary(key) do
    # Extract TS storage from handle_state and use it directly
    ts_storage = handle_state.ts_storage
    Vdr.TS.get(ts_storage, db, key)
  end

  # List accessors
  def llen(%{ts_storage: ts_storage}, db, key) when is_binary(key) do
    case Vdr.TS.llen(ts_storage, db, key) do
      {:ok, len} -> len
      {:error, _} = error -> error
    end
  end

  def lrange(%{ts_storage: ts_storage}, db, key, start, stop) when is_binary(key) do
    case Vdr.TS.lrange(ts_storage, db, key, start, stop) do
      {:ok, elements} -> elements
      {:error, _} = error -> error
    end
  end

  def smembers(%{ts_storage: ts_storage}, db, key) when is_binary(key) do
    case Vdr.TS.smembers(ts_storage, db, key) do
      {:ok, members} -> members
      {:error, _} = error -> error
    end
  end

  def scard(%{ts_storage: ts_storage}, db, key) when is_binary(key) do
    case Vdr.TS.scard(ts_storage, db, key) do
      {:ok, count} -> count
      {:error, _} = error -> error
    end
  end

  def sismember(%{ts_storage: ts_storage}, db, key, member)
      when is_binary(key) and is_binary(member) do
    case Vdr.TS.sismember(ts_storage, db, key, member) do
      {:ok, is_member} -> is_member
      {:error, _} = error -> error
    end
  end

  def sfirst(%{ts_storage: ts_storage}, db, key) when is_binary(key) do
    case Vdr.TS.sfirst(ts_storage, db, key) do
      {:ok, member} -> member
      {:error, _} = error -> error
    end
  end

  def slast(%{ts_storage: ts_storage}, db, key) when is_binary(key) do
    case Vdr.TS.slast(ts_storage, db, key) do
      {:ok, member} -> member
      {:error, _} = error -> error
    end
  end

  def snext(%{ts_storage: ts_storage}, db, key, member)
      when is_binary(key) and is_binary(member) do
    case Vdr.TS.snext(ts_storage, db, key, member) do
      {:ok, next_member} -> next_member
      {:error, _} = error -> error
    end
  end

  def sprev(%{ts_storage: ts_storage}, db, key, member)
      when is_binary(key) and is_binary(member) do
    case Vdr.TS.sprev(ts_storage, db, key, member) do
      {:ok, prev_member} -> prev_member
      {:error, _} = error -> error
    end
  end

  # Hash accessors
  def hget(%{ts_storage: ts_storage}, db, key, field)
      when is_binary(key) and is_binary(field) do
    case Vdr.TS.hget(ts_storage, db, key, field) do
      {:ok, value} -> value
      {:error, _} = error -> error
    end
  end

  def hmget(%{ts_storage: ts_storage}, db, key, fields)
      when is_binary(key) and is_list(fields) do
    case Vdr.TS.hmget(ts_storage, db, key, fields) do
      {:ok, values} -> values
      {:error, _} = error -> error
    end
  end

  def hgetall(%{ts_storage: ts_storage}, db, key) when is_binary(key) do
    case Vdr.TS.hgetall(ts_storage, db, key) do
      {:ok, pairs} -> pairs
      {:error, _} = error -> error
    end
  end

  def hkeys(%{ts_storage: ts_storage}, db, key) when is_binary(key) do
    case Vdr.TS.hkeys(ts_storage, db, key) do
      {:ok, keys} -> keys
      {:error, _} = error -> error
    end
  end

  def hvals(%{ts_storage: ts_storage}, db, key) when is_binary(key) do
    case Vdr.TS.hvals(ts_storage, db, key) do
      {:ok, values} -> values
      {:error, _} = error -> error
    end
  end

  def hlen(%{ts_storage: ts_storage}, db, key) when is_binary(key) do
    case Vdr.TS.hlen(ts_storage, db, key) do
      {:ok, len} -> len
      {:error, _} = error -> error
    end
  end

  # Sorted set accessors
  def zrange(%{ts_storage: ts_storage}, db, key, start, stop, with_scores)
      when is_binary(key) do
    case Vdr.TS.zrange(ts_storage, db, key, start, stop, with_scores) do
      {:ok, flat_list} when with_scores ->
        # Convert flat list [member1, score1, member2, score2, ...] to [{member1, score1}, {member2, score2}, ...]
        flat_list
        |> Enum.chunk_every(2)
        |> Enum.map(fn [member, score] -> {member, score} end)

      {:ok, members} ->
        # Return members only (without scores)
        members

      {:error, _} = error ->
        error
    end
  end

  def zcard(%{ts_storage: ts_storage}, db, key) when is_binary(key) do
    case Vdr.TS.zcard(ts_storage, db, key) do
      {:ok, count} -> count
      {:error, _} = error -> error
    end
  end

  def zscore(%{ts_storage: ts_storage}, db, key, member)
      when is_binary(key) and is_binary(member) do
    case Vdr.TS.zscore(ts_storage, db, key, member) do
      {:ok, score} -> score
      {:error, _} = error -> error
    end
  end

  def zrangebyscore(%{ts_storage: ts_storage}, db, key, min, max, with_scores)
      when is_binary(key) do
    case Vdr.TS.zrangebyscore(ts_storage, db, key, min, max, with_scores) do
      {:ok, result} -> result
      {:error, _} = error -> error
    end
  end

  def zrank(%{ts_storage: ts_storage}, db, key, member)
      when is_binary(key) and is_binary(member) do
    case Vdr.TS.zrank(ts_storage, db, key, member) do
      {:ok, rank} -> rank
      {:error, _} = error -> error
    end
  end

  def zrevrank(%{ts_storage: ts_storage}, db, key, member)
      when is_binary(key) and is_binary(member) do
    case Vdr.TS.zrevrank(ts_storage, db, key, member) do
      {:ok, rank} -> rank
      {:error, _} = error -> error
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
  @spec tx(%{ts_storage: reference()}, non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def tx(%{ts_storage: ts_storage}, db, script) when is_binary(script) do
    Vdr.TS.read_tx(ts_storage, db, script)
  end

  # Convert RedisCommand to tuple format for NIF
  defp convert_command(db, %RedisCommand.Set{key: key, value: value}) do
    {db, {:set, key, value}}
  end

  defp convert_command(db, %RedisCommand.Del{keys: keys}) do
    {db, {:del, keys}}
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

  defp convert_command(db, %RedisCommand.LPop{key: key}) do
    {db, {:lpop, key}}
  end

  defp convert_command(db, %RedisCommand.RPop{key: key}) do
    {db, {:rpop, key}}
  end

  defp convert_command(db, %RedisCommand.LSet{key: key, index: index, value: value}) do
    {db, {:lset, key, index, value}}
  end

  defp convert_command(db, %RedisCommand.RPopLPush{source: source_key, destination: dest_key}) do
    {db, {:rpoplpush, source_key, dest_key}}
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

  defp convert_command(db, %RedisCommand.HIncrByFloat{key: key, field: field, increment: increment}) do
    {db, {:hincrbyfloat, key, field, increment}}
  end

  defp convert_command(db, %RedisCommand.HSetEX{key: key, nx_xx_option: nx_xx_option, fields: fields}) do
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

  defp convert_command(db, %RedisCommand.Rename{key: old_key, newkey: new_key}) do
    {db, {:rename, old_key, new_key}}
  end

  defp convert_command(db, %RedisCommand.RenameNX{key: old_key, newkey: new_key}) do
    {db, {:renamenx, old_key, new_key}}
  end

  defp convert_command(db, %RedisCommand.Move{key: key, db: target_db}) do
    {db, {:move_key, key, target_db}}
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

  # Unified command handler using the common NIF
  defp do_handle_command(ts_storage, db, command) do
    # Convert the command to tuple format
    case convert_command(db, command) do
      nil ->
        # Command not supported, ignore
        :ok

      cmd_tuple ->
        # Execute the command via the common NIF
        [_result] = Vdr.TS.tx(ts_storage, [cmd_tuple])
        :ok
    end
  end

  # Transaction helper functions

  defp apply_transaction(%__MODULE__{tx_buffer: buffer} = state) do
    # Reverse the buffer since we prepended commands
    commands = Enum.reverse(buffer)

    # Apply all commands to the appropriate ts_storage
    Enum.each(commands, fn {db, command} ->
      execute_command(state, db, command)
    end)

    state
  end

  defp execute_command(%__MODULE__{} = state, db, command) do
    if state.new_ts_storage do
      # Writing to new_ts_storage during RDB transfer
      do_handle_command(state.new_ts_storage, db, command)
    else
      # Writing to ts_storage during streaming
      do_handle_command(state.ts_storage, db, command)
    end
  end
end
