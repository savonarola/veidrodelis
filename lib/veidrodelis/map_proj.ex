defmodule Vdr.MapProj do
  @moduledoc """
  Map-based Redis replication stream processor with typed stores.

  This module provides the core implementation for processing Redis replication streams
  with automatic key type tracking and routing to specialized stores, all using pure Elixir maps.
  All keys and values are stored as raw binaries.
  """

  require Logger

  @behaviour Vdr.RedisStream.Callback

  alias Vdr.RedisStream.{Command, Replica}
  alias Command, as: RedisCommand
  alias Vdr.MapProj.{Strings, Lists, Sets, Hashes, ZSets, Common}

  @tx_key "__vdr_tx"

  defstruct [:store, :id, :new_store, :ready, :tx_buffer, :in_transaction]

  @type key :: binary()
  @type value :: binary()

  @type t :: %__MODULE__{
          store: map(),
          id: term(),
          new_store: map() | nil,
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

    # Register immediately so queries can be made right after start_link
    :ok =
      Vdr.Registry.register(self(), id, %Vdr.Handle{
        callback_module: __MODULE__,
        handle_state: self(),
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
    # Replace current store with new_store
    # Set ready flag to true
    # Clear new_store
    new_state = %{state | store: state.new_store, new_store: nil, ready: true}
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
        updated_state = execute_command(state, db, cmd)
        {:ok, updated_state}
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
    updated_state = execute_command(state, db, command)
    {:ok, updated_state}
  end

  @impl Vdr.RedisStream.Callback
  def handle_call(%__MODULE__{} = state, message) do
    # Check if ready to serve reads
    if not state.ready do
      {:reply, {:error, :not_ready}, state}
    else
      # Serve reads from current store (not new_store)
      case message do
        {:get, db, key} ->
          result = Strings.get(state.store, db, key)
          {:reply, result, state}

        {:llen, db, key} ->
          result = Lists.llen(state.store, db, key)
          {:reply, result, state}

        {:lrange, db, key, start_idx, stop_idx} ->
          result = Lists.lrange(state.store, db, key, start_idx, stop_idx)
          {:reply, result, state}

        {:smembers, db, key} ->
          result = Sets.smembers(state.store, db, key)
          {:reply, result, state}

        {:scard, db, key} ->
          result = Sets.scard(state.store, db, key)
          {:reply, result, state}

        {:hget, db, key, field} ->
          result = Hashes.hget(state.store, db, key, field)
          {:reply, result, state}

        {:hmget, db, key, fields} ->
          result = Enum.map(fields, fn field -> Hashes.hget(state.store, db, key, field) end)
          {:reply, result, state}

        {:hgetall, db, key} ->
          result = Hashes.hgetall(state.store, db, key)
          {:reply, result, state}

        {:hkeys, db, key} ->
          result = Hashes.hkeys(state.store, db, key)
          {:reply, result, state}

        {:hvals, db, key} ->
          result = Hashes.hvals(state.store, db, key)
          {:reply, result, state}

        {:hlen, db, key} ->
          result = Hashes.hlen(state.store, db, key)
          {:reply, result, state}

        {:zrange, db, key, start_idx, stop_idx} ->
          result = ZSets.zrange(state.store, db, key, start_idx, stop_idx)
          {:reply, result, state}

        {:zcard, db, key} ->
          result = ZSets.zcard(state.store, db, key)
          {:reply, result, state}

        {:zscore, db, key, member} ->
          result = ZSets.zscore(state.store, db, key, member)
          {:reply, result, state}

        _ ->
          {:error, :unknown_command}
      end
    end
  end

  @impl Vdr.RedisStream.Callback
  def handle_destroy(%__MODULE__{}) do
    # No cleanup needed for map-based stores
    :ok
  end

  def handle_destroy(_state) do
    :ok
  end

  # Private functions

  defp initialize_state(id) do
    %__MODULE__{
      id: id,
      store: %{},
      new_store: nil,
      ready: false,
      tx_buffer: [],
      in_transaction: false
    }
  end

  defp reinitialize_state(%__MODULE__{} = state) do
    # Create new_store for incoming RDB data
    # Keep current store for serving reads during RDB transfer
    # Keep ready flag as-is (true after first sync, false initially)
    # Clear any ongoing transaction on reconnection
    new_state = %{state | new_store: %{}, tx_buffer: [], in_transaction: false}

    # Registry is already registered in init, no need to re-register
    {:ok, new_state}
  end

  # Public accessor functions
  # On success: returns value (could be nil, string, list, etc.)
  # On error: returns {:error, reason} (e.g., {:error, :not_ready})

  def get(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:get, db, key}) do
      {:ok, value} -> value
      error -> error
    end
  end

  def llen(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:llen, db, key}) do
      {:ok, value} -> value
      error -> error
    end
  end

  def lrange(pid, db, key, start_idx, stop_idx) when is_pid(pid) do
    case Replica.call(pid, {:lrange, db, key, start_idx, stop_idx}) do
      {:ok, value} -> value
      error -> error
    end
  end

  def smembers(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:smembers, db, key}) do
      {:ok, value} -> value
      error -> error
    end
  end

  def scard(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:scard, db, key}) do
      {:ok, value} -> value
      error -> error
    end
  end

  def hget(pid, db, key, field) when is_pid(pid) do
    case Replica.call(pid, {:hget, db, key, field}) do
      {:ok, value} -> value
      error -> error
    end
  end

  def hmget(pid, db, key, fields) when is_pid(pid) do
    case Replica.call(pid, {:hmget, db, key, fields}) do
      {:ok, value} -> value
      error -> error
    end
  end

  def hgetall(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:hgetall, db, key}) do
      {:ok, value} -> value
      error -> error
    end
  end

  def hkeys(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:hkeys, db, key}) do
      {:ok, value} -> value
      error -> error
    end
  end

  def hvals(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:hvals, db, key}) do
      {:ok, value} -> value
      error -> error
    end
  end

  def hlen(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:hlen, db, key}) do
      {:ok, value} -> value
      error -> error
    end
  end

  def zrange(pid, db, key, start_idx, stop_idx) when is_pid(pid) do
    case Replica.call(pid, {:zrange, db, key, start_idx, stop_idx}) do
      {:ok, value} -> value
      error -> error
    end
  end

  def zcard(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:zcard, db, key}) do
      {:ok, value} -> value
      error -> error
    end
  end

  def zscore(pid, db, key, member) when is_pid(pid) do
    case Replica.call(pid, {:zscore, db, key, member}) do
      {:ok, value} -> value
      error -> error
    end
  end

  @doc """
  Lua transactions are not supported in MapProj.
  Use TSProj for Lua transaction support.
  """
  def tx(_pid, _db, _script) do
    {:error, :not_supported}
  end

  defp do_handle_command(store, db, %RedisCommand.Set{key: key, value: value}) do
    Strings.set(store, db, key, value)
  end

  defp do_handle_command(store, db, %RedisCommand.MSet{pairs: pairs}) do
    Strings.mset(store, db, pairs)
  end

  defp do_handle_command(store, db, %RedisCommand.Append{key: key, value: value}) do
    Strings.append(store, db, key, value)
  end

  defp do_handle_command(store, db, %RedisCommand.SetRange{
         key: key,
         offset: offset,
         value: value
       }) do
    Strings.setrange(store, db, key, offset, value)
  end

  defp do_handle_command(store, db, %RedisCommand.SetBit{key: key, offset: offset, value: bit}) do
    Strings.setbit(store, db, key, offset, bit)
  end

  # List commands
  defp do_handle_command(store, db, %RedisCommand.RPush{key: key, values: values}) do
    Lists.rpush(store, db, key, values)
  end

  defp do_handle_command(store, db, %RedisCommand.LPush{key: key, values: values}) do
    Lists.lpush(store, db, key, values)
  end

  defp do_handle_command(store, db, %RedisCommand.RPushX{key: key, values: values}) do
    Lists.rpushx(store, db, key, values)
  end

  defp do_handle_command(store, db, %RedisCommand.LPushX{key: key, values: values}) do
    Lists.lpushx(store, db, key, values)
  end

  defp do_handle_command(store, db, %RedisCommand.LPop{key: key}) do
    Lists.lpop(store, db, key)
  end

  defp do_handle_command(store, db, %RedisCommand.RPop{key: key}) do
    Lists.rpop(store, db, key)
  end

  defp do_handle_command(store, db, %RedisCommand.LRem{key: key, count: count, value: value}) do
    Lists.lrem(store, db, key, count, value)
  end

  defp do_handle_command(store, db, %RedisCommand.LTrim{
         key: key,
         start: start_idx,
         stop: stop_idx
       }) do
    Lists.ltrim(store, db, key, start_idx, stop_idx)
  end

  defp do_handle_command(store, db, %RedisCommand.LSet{key: key, index: index, value: value}) do
    Lists.lset(store, db, key, index, value)
  end

  defp do_handle_command(
         store,
         db,
         %RedisCommand.LInsert{key: key, before_after: position, pivot: pivot, element: element}
       ) do
    Lists.linsert(store, db, key, position, pivot, element)
  end

  defp do_handle_command(store, db, %RedisCommand.RPopLPush{
         source: source,
         destination: dest
       }) do
    Lists.rpoplpush(store, db, source, dest)
  end

  defp do_handle_command(store, db, %RedisCommand.SAdd{key: key, members: members}) do
    Sets.sadd(store, db, key, members)
  end

  defp do_handle_command(store, db, %RedisCommand.SRem{key: key, members: members}) do
    Sets.srem(store, db, key, members)
  end

  defp do_handle_command(store, db, %RedisCommand.SMove{
         source: source,
         destination: dest,
         member: member
       }) do
    Sets.smove(store, db, source, dest, member)
  end

  defp do_handle_command(store, db, %RedisCommand.SInterStore{destination: dest, keys: keys}) do
    Sets.sinterstore(store, db, dest, keys)
  end

  defp do_handle_command(store, db, %RedisCommand.SUnionStore{destination: dest, keys: keys}) do
    Sets.sunionstore(store, db, dest, keys)
  end

  defp do_handle_command(store, db, %RedisCommand.SDiffStore{destination: dest, keys: keys}) do
    Sets.sdiffstore(store, db, dest, keys)
  end

  defp do_handle_command(store, db, %RedisCommand.HSet{key: key, fields: field_values}) do
    Hashes.hset(store, db, key, field_values)
  end

  defp do_handle_command(store, db, %RedisCommand.HDel{key: key, fields: fields}) do
    Hashes.hdel(store, db, key, fields)
  end

  defp do_handle_command(store, db, %RedisCommand.ZAdd{key: key, members: members}) do
    ZSets.zadd(store, db, key, members)
  end

  defp do_handle_command(store, db, %RedisCommand.ZRem{key: key, members: members}) do
    ZSets.zrem(store, db, key, members)
  end

  defp do_handle_command(store, db, %RedisCommand.ZPopMax{key: key, count: count}) do
    {new_store, _popped} = ZSets.zpopmax(store, db, key, count)
    new_store
  end

  defp do_handle_command(store, db, %RedisCommand.ZPopMin{key: key, count: count}) do
    {new_store, _popped} = ZSets.zpopmin(store, db, key, count)
    new_store
  end

  defp do_handle_command(store, db, %RedisCommand.ZRemRangeByRank{
         key: key,
         start: start_idx,
         stop: stop_idx
       }) do
    ZSets.zremrangebyrank(store, db, key, start_idx, stop_idx)
  end

  defp do_handle_command(store, db, %RedisCommand.ZRemRangeByScore{key: key, min: min, max: max}) do
    min_score = parse_score(min)
    max_score = parse_score(max)
    ZSets.zremrangebyscore(store, db, key, min_score, max_score)
  end

  defp do_handle_command(store, db, %RedisCommand.ZRemRangeByLex{key: key, min: min, max: max}) do
    ZSets.zremrangebylex(store, db, key, min, max)
  end

  defp do_handle_command(store, db, %RedisCommand.ZUnionStore{
         destination: dest,
         keys: keys,
         weights: weights,
         aggregate: aggregate
       }) do
    ZSets.zunionstore(
      store,
      db,
      dest,
      keys,
      weights || [],
      aggregate || :sum
    )
  end

  defp do_handle_command(store, db, %RedisCommand.ZInterStore{
         destination: dest,
         keys: keys,
         weights: weights,
         aggregate: aggregate
       }) do
    ZSets.zinterstore(
      store,
      db,
      dest,
      keys,
      weights || [],
      aggregate || :sum
    )
  end

  defp do_handle_command(store, db, %RedisCommand.Del{keys: keys}) do
    Enum.reduce(keys, store, fn key, acc_store ->
      Common.del(acc_store, db, key)
    end)
  end

  defp do_handle_command(store, _db, %RedisCommand.PExpireAt{}) do
    store
  end

  defp do_handle_command(store, _db, _command) do
    store
  end

  defp parse_score("-inf"), do: :neg_inf
  defp parse_score("+inf"), do: :pos_inf

  defp parse_score(bin) when is_binary(bin) do
    case Float.parse(bin) do
      {score, _} -> score
      :error -> 0.0
    end
  end

  # Transaction helper functions

  defp apply_transaction(%__MODULE__{tx_buffer: buffer} = state) do
    # Reverse the buffer since we prepended commands
    commands = Enum.reverse(buffer)

    # Apply all commands to the appropriate store
    Enum.reduce(commands, state, fn {db, command}, acc_state ->
      execute_command(acc_state, db, command)
    end)
  end

  defp execute_command(%__MODULE__{} = state, db, command) do
    if state.new_store do
      # Writing to new_store during RDB transfer
      updated_new_store = do_handle_command(state.new_store, db, command)
      %{state | new_store: updated_new_store}
    else
      # Writing to store during streaming
      updated_store = do_handle_command(state.store, db, command)
      %{state | store: updated_store}
    end
  end
end
