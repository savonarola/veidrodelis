defmodule Vdr.MapProj do
  @moduledoc """
  Map-based Redis replication stream processor with typed stores.

  This module provides the core implementation for processing Redis replication streams
  with automatic key type tracking and routing to specialized stores, all using pure Elixir maps.
  All keys and values are stored as raw binaries.
  """

  require Logger

  @behaviour Vdr.RedisStream.Callback

  alias Vdr.Command
  alias Vdr.MapProj.{Strings, Lists, Sets, Hashes, ZSets, Common}

  defstruct [:store]

  @type key :: binary()
  @type value :: binary()

  @type t :: %__MODULE__{
          store: map()
        }

  # Public API

  @doc """
  Starts a MapProj instance that connects to Redis and processes replication stream.

  ## Options

    * `:host` - Redis host (default: "localhost")
    * `:port` - Redis port (default: 6379)
    * `:username` - Redis username for ACL authentication (default: nil)
    * `:password` - Redis password (default: nil)
    * `:ssl` - Use SSL/TLS (default: false)
    * `:ssl_opts` - SSL options (default: [])
    * `:reconnect` - Enable automatic reconnection (default: true)
    * `:reconnect_delay_ms` - Initial delay before reconnection in ms (default: 1000)
    * `:max_reconnect_delay_ms` - Maximum delay between reconnection attempts in ms (default: 30000)

  ## Returns

    * `{:ok, pid}` - Successfully started (returns Replica GenServer PID)
    * `{:error, reason}` - Failed to start
  """
  def start_link(opts) do
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

    initial_state = %{}

    replica_opts =
      [
        callback_module: __MODULE__,
        callback_state: initial_state
      ] ++ redis_opts

    Vdr.RedisStream.Replica.start_link(replica_opts)
  end

  @doc """
  Stops a MapProj instance.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid)
  end

  @doc """
  Gets the current replication state of a MapProj instance.
  """
  @spec get_replication_state(pid()) :: atom()
  def get_replication_state(pid) when is_pid(pid) do
    Vdr.RedisStream.Replica.get_replication_state(pid)
  end

  # RedisStream.Callback implementation

  @impl Vdr.RedisStream.Callback
  def handle_replication_start(%__MODULE__{} = state) do
    reinitialize_state(state)
  end

  def handle_replication_start(init_opts) do
    initialize_state(init_opts)
  end

  @impl Vdr.RedisStream.Callback
  def handle_command(%__MODULE__{} = state, db, command) do
    new_store = do_handle_command(state, db, command)
    {:ok, %{state | store: new_store}}
  end

  @impl Vdr.RedisStream.Callback
  def handle_call(%__MODULE__{} = state, message) do
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

  @impl Vdr.RedisStream.Callback
  def handle_destroy(%__MODULE__{}) do
    # No cleanup needed for map-based stores
    :ok
  end

  def handle_destroy(_state) do
    :ok
  end

  # Private functions

  defp initialize_state(_init_opts) do
    state = %__MODULE__{
      store: %{}
    }

    {:ok, state}
  end

  defp reinitialize_state(%__MODULE__{}) do
    initialize_state(%{})
  end

  # Command handlers

  defp do_handle_command(state, db, %Command.Set{key: key, value: value}) do
    Strings.set(state.store, db, key, value)
  end

  defp do_handle_command(state, db, %Command.MSet{pairs: pairs}) do
    Strings.mset(state.store, db, pairs)
  end

  defp do_handle_command(state, db, %Command.Append{key: key, value: value}) do
    Strings.append(state.store, db, key, value)
  end

  defp do_handle_command(state, db, %Command.SetRange{
         key: key,
         offset: offset,
         value: value
       }) do
    Strings.setrange(state.store, db, key, offset, value)
  end

  defp do_handle_command(state, db, %Command.SetBit{key: key, offset: offset, value: bit}) do
    Strings.setbit(state.store, db, key, offset, bit)
  end

  # List commands
  defp do_handle_command(state, db, %Command.RPush{key: key, values: values}) do
    Lists.rpush(state.store, db, key, values)
  end

  defp do_handle_command(state, db, %Command.LPush{key: key, values: values}) do
    Lists.lpush(state.store, db, key, values)
  end

  defp do_handle_command(state, db, %Command.RPushX{key: key, values: values}) do
    Lists.rpushx(state.store, db, key, values)
  end

  defp do_handle_command(state, db, %Command.LPushX{key: key, values: values}) do
    Lists.lpushx(state.store, db, key, values)
  end

  defp do_handle_command(state, db, %Command.LPop{key: key}) do
    Lists.lpop(state.store, db, key)
  end

  defp do_handle_command(state, db, %Command.RPop{key: key}) do
    Lists.rpop(state.store, db, key)
  end

  defp do_handle_command(state, db, %Command.LRem{key: key, count: count, value: value}) do
    Lists.lrem(state.store, db, key, count, value)
  end

  defp do_handle_command(state, db, %Command.LTrim{
         key: key,
         start: start_idx,
         stop: stop_idx
       }) do
    Lists.ltrim(state.store, db, key, start_idx, stop_idx)
  end

  defp do_handle_command(state, db, %Command.LSet{key: key, index: index, value: value}) do
    Lists.lset(state.store, db, key, index, value)
  end

  defp do_handle_command(
         state,
         db,
         %Command.LInsert{key: key, before_after: position, pivot: pivot, element: element}
       ) do
    Lists.linsert(state.store, db, key, position, pivot, element)
  end

  defp do_handle_command(state, db, %Command.RPopLPush{
         source: source,
         destination: dest
       }) do
    Lists.rpoplpush(state.store, db, source, dest)
  end

  defp do_handle_command(state, db, %Command.SAdd{key: key, members: members}) do
    Sets.sadd(state.store, db, key, members)
  end

  defp do_handle_command(state, db, %Command.SRem{key: key, members: members}) do
    Sets.srem(state.store, db, key, members)
  end

  defp do_handle_command(state, db, %Command.SMove{
         source: source,
         destination: dest,
         member: member
       }) do
    Sets.smove(state.store, db, source, dest, member)
  end

  defp do_handle_command(state, db, %Command.SInterStore{destination: dest, keys: keys}) do
    Sets.sinterstore(state.store, db, dest, keys)
  end

  defp do_handle_command(state, db, %Command.SUnionStore{destination: dest, keys: keys}) do
    Sets.sunionstore(state.store, db, dest, keys)
  end

  defp do_handle_command(state, db, %Command.SDiffStore{destination: dest, keys: keys}) do
    Sets.sdiffstore(state.store, db, dest, keys)
  end

  defp do_handle_command(state, db, %Command.HSet{key: key, fields: field_values}) do
    Hashes.hset(state.store, db, key, field_values)
  end

  defp do_handle_command(state, db, %Command.HDel{key: key, fields: fields}) do
    Hashes.hdel(state.store, db, key, fields)
  end

  defp do_handle_command(state, db, %Command.ZAdd{key: key, members: members}) do
    ZSets.zadd(state.store, db, key, members)
  end

  defp do_handle_command(state, db, %Command.ZRem{key: key, members: members}) do
    ZSets.zrem(state.store, db, key, members)
  end

  defp do_handle_command(state, db, %Command.ZPopMax{key: key, count: count}) do
    {new_store, _popped} = ZSets.zpopmax(state.store, db, key, count)
    new_store
  end

  defp do_handle_command(state, db, %Command.ZPopMin{key: key, count: count}) do
    {new_store, _popped} = ZSets.zpopmin(state.store, db, key, count)
    new_store
  end

  defp do_handle_command(state, db, %Command.ZRemRangeByRank{
         key: key,
         start: start_idx,
         stop: stop_idx
       }) do
    ZSets.zremrangebyrank(state.store, db, key, start_idx, stop_idx)
  end

  defp do_handle_command(state, db, %Command.ZRemRangeByScore{key: key, min: min, max: max}) do
    min_score = parse_score(min)
    max_score = parse_score(max)
    ZSets.zremrangebyscore(state.store, db, key, min_score, max_score)
  end

  defp do_handle_command(state, db, %Command.ZRemRangeByLex{key: key, min: min, max: max}) do
    ZSets.zremrangebylex(state.store, db, key, min, max)
  end

  defp do_handle_command(state, db, %Command.ZUnionStore{
         destination: dest,
         keys: keys,
         weights: weights,
         aggregate: aggregate
       }) do
    ZSets.zunionstore(
      state.store,
      db,
      dest,
      keys,
      weights || [],
      aggregate || :sum
    )
  end

  defp do_handle_command(state, db, %Command.ZInterStore{
         destination: dest,
         keys: keys,
         weights: weights,
         aggregate: aggregate
       }) do
    ZSets.zinterstore(
      state.store,
      db,
      dest,
      keys,
      weights || [],
      aggregate || :sum
    )
  end

  defp do_handle_command(state, db, %Command.Del{keys: keys}) do
    Enum.reduce(keys, state.store, fn key, store ->
      Common.del(store, db, key)
    end)
  end

  defp do_handle_command(state, _db, %Command.PExpireAt{}) do
    state.store
  end

  defp do_handle_command(state, _db, _command) do
    state.store
  end

  defp parse_score("-inf"), do: :neg_inf
  defp parse_score("+inf"), do: :pos_inf

  defp parse_score(bin) when is_binary(bin) do
    case Float.parse(bin) do
      {score, _} -> score
      :error -> 0.0
    end
  end
end
