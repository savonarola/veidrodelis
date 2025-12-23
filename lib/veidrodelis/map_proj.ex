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

  defstruct [:store, :id]

  @type key :: binary()
  @type value :: binary()

  @type t :: %__MODULE__{
          store: map()
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
    {:ok, state}
  end

  @impl Vdr.RedisStream.Callback
  def handle_replication_start(state) do
    reinitialize_state(state)
  end

  @impl Vdr.RedisStream.Callback
  def handle_command(%__MODULE__{} = state, %Vdr.RedisStream.ReplicaCommand{
        db: db,
        command: command
      }) do
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

  defp initialize_state(id) do
    %__MODULE__{
      id: id,
      store: %{}
    }
  end

  defp reinitialize_state(%__MODULE__{id: id}) do
    state = %__MODULE__{
      id: id,
      store: %{}
    }

    :ok =
      Vdr.Registry.register(self(), id, %Vdr.Handle{
        callback_module: __MODULE__,
        handle_state: self()
      })

    {:ok, state}
  end

  # Public accessor functions

  def get(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:get, db, key}) do
      {:ok, value} -> value
      {:error, reason} -> {:error, reason}
    end
  end

  def llen(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:llen, db, key}) do
      {:ok, len} -> len
      {:error, reason} -> {:error, reason}
    end
  end

  def lrange(pid, db, key, start_idx, stop_idx) when is_pid(pid) do
    case Replica.call(pid, {:lrange, db, key, start_idx, stop_idx}) do
      {:ok, elements} -> elements
      {:error, reason} -> {:error, reason}
    end
  end

  def smembers(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:smembers, db, key}) do
      {:ok, members} -> members
      {:error, reason} -> {:error, reason}
    end
  end

  def scard(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:scard, db, key}) do
      {:ok, count} -> count
      {:error, reason} -> {:error, reason}
    end
  end

  def hget(pid, db, key, field) when is_pid(pid) do
    case Replica.call(pid, {:hget, db, key, field}) do
      {:ok, value} -> value
      {:error, reason} -> {:error, reason}
    end
  end

  def hmget(pid, db, key, fields) when is_pid(pid) do
    case Replica.call(pid, {:hmget, db, key, fields}) do
      {:ok, values} -> values
      {:error, reason} -> {:error, reason}
    end
  end

  def hgetall(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:hgetall, db, key}) do
      {:ok, fields} -> fields
      {:error, reason} -> {:error, reason}
    end
  end

  def hkeys(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:hkeys, db, key}) do
      {:ok, keys} -> keys
      {:error, reason} -> {:error, reason}
    end
  end

  def hvals(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:hvals, db, key}) do
      {:ok, values} -> values
      {:error, reason} -> {:error, reason}
    end
  end

  def hlen(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:hlen, db, key}) do
      {:ok, len} -> len
      {:error, reason} -> {:error, reason}
    end
  end

  def zrange(pid, db, key, start_idx, stop_idx) when is_pid(pid) do
    case Replica.call(pid, {:zrange, db, key, start_idx, stop_idx}) do
      {:ok, members} -> members
      {:error, reason} -> {:error, reason}
    end
  end

  def zcard(pid, db, key) when is_pid(pid) do
    case Replica.call(pid, {:zcard, db, key}) do
      {:ok, count} -> count
      {:error, reason} -> {:error, reason}
    end
  end

  def zscore(pid, db, key, member) when is_pid(pid) do
    case Replica.call(pid, {:zscore, db, key, member}) do
      {:ok, score} -> score
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_handle_command(state, db, %RedisCommand.Set{key: key, value: value}) do
    Strings.set(state.store, db, key, value)
  end

  defp do_handle_command(state, db, %RedisCommand.MSet{pairs: pairs}) do
    Strings.mset(state.store, db, pairs)
  end

  defp do_handle_command(state, db, %RedisCommand.Append{key: key, value: value}) do
    Strings.append(state.store, db, key, value)
  end

  defp do_handle_command(state, db, %RedisCommand.SetRange{
         key: key,
         offset: offset,
         value: value
       }) do
    Strings.setrange(state.store, db, key, offset, value)
  end

  defp do_handle_command(state, db, %RedisCommand.SetBit{key: key, offset: offset, value: bit}) do
    Strings.setbit(state.store, db, key, offset, bit)
  end

  # List commands
  defp do_handle_command(state, db, %RedisCommand.RPush{key: key, values: values}) do
    Lists.rpush(state.store, db, key, values)
  end

  defp do_handle_command(state, db, %RedisCommand.LPush{key: key, values: values}) do
    Lists.lpush(state.store, db, key, values)
  end

  defp do_handle_command(state, db, %RedisCommand.RPushX{key: key, values: values}) do
    Lists.rpushx(state.store, db, key, values)
  end

  defp do_handle_command(state, db, %RedisCommand.LPushX{key: key, values: values}) do
    Lists.lpushx(state.store, db, key, values)
  end

  defp do_handle_command(state, db, %RedisCommand.LPop{key: key}) do
    Lists.lpop(state.store, db, key)
  end

  defp do_handle_command(state, db, %RedisCommand.RPop{key: key}) do
    Lists.rpop(state.store, db, key)
  end

  defp do_handle_command(state, db, %RedisCommand.LRem{key: key, count: count, value: value}) do
    Lists.lrem(state.store, db, key, count, value)
  end

  defp do_handle_command(state, db, %RedisCommand.LTrim{
         key: key,
         start: start_idx,
         stop: stop_idx
       }) do
    Lists.ltrim(state.store, db, key, start_idx, stop_idx)
  end

  defp do_handle_command(state, db, %RedisCommand.LSet{key: key, index: index, value: value}) do
    Lists.lset(state.store, db, key, index, value)
  end

  defp do_handle_command(
         state,
         db,
         %RedisCommand.LInsert{key: key, before_after: position, pivot: pivot, element: element}
       ) do
    Lists.linsert(state.store, db, key, position, pivot, element)
  end

  defp do_handle_command(state, db, %RedisCommand.RPopLPush{
         source: source,
         destination: dest
       }) do
    Lists.rpoplpush(state.store, db, source, dest)
  end

  defp do_handle_command(state, db, %RedisCommand.SAdd{key: key, members: members}) do
    Sets.sadd(state.store, db, key, members)
  end

  defp do_handle_command(state, db, %RedisCommand.SRem{key: key, members: members}) do
    Sets.srem(state.store, db, key, members)
  end

  defp do_handle_command(state, db, %RedisCommand.SMove{
         source: source,
         destination: dest,
         member: member
       }) do
    Sets.smove(state.store, db, source, dest, member)
  end

  defp do_handle_command(state, db, %RedisCommand.SInterStore{destination: dest, keys: keys}) do
    Sets.sinterstore(state.store, db, dest, keys)
  end

  defp do_handle_command(state, db, %RedisCommand.SUnionStore{destination: dest, keys: keys}) do
    Sets.sunionstore(state.store, db, dest, keys)
  end

  defp do_handle_command(state, db, %RedisCommand.SDiffStore{destination: dest, keys: keys}) do
    Sets.sdiffstore(state.store, db, dest, keys)
  end

  defp do_handle_command(state, db, %RedisCommand.HSet{key: key, fields: field_values}) do
    Hashes.hset(state.store, db, key, field_values)
  end

  defp do_handle_command(state, db, %RedisCommand.HDel{key: key, fields: fields}) do
    Hashes.hdel(state.store, db, key, fields)
  end

  defp do_handle_command(state, db, %RedisCommand.ZAdd{key: key, members: members}) do
    ZSets.zadd(state.store, db, key, members)
  end

  defp do_handle_command(state, db, %RedisCommand.ZRem{key: key, members: members}) do
    ZSets.zrem(state.store, db, key, members)
  end

  defp do_handle_command(state, db, %RedisCommand.ZPopMax{key: key, count: count}) do
    {new_store, _popped} = ZSets.zpopmax(state.store, db, key, count)
    new_store
  end

  defp do_handle_command(state, db, %RedisCommand.ZPopMin{key: key, count: count}) do
    {new_store, _popped} = ZSets.zpopmin(state.store, db, key, count)
    new_store
  end

  defp do_handle_command(state, db, %RedisCommand.ZRemRangeByRank{
         key: key,
         start: start_idx,
         stop: stop_idx
       }) do
    ZSets.zremrangebyrank(state.store, db, key, start_idx, stop_idx)
  end

  defp do_handle_command(state, db, %RedisCommand.ZRemRangeByScore{key: key, min: min, max: max}) do
    min_score = parse_score(min)
    max_score = parse_score(max)
    ZSets.zremrangebyscore(state.store, db, key, min_score, max_score)
  end

  defp do_handle_command(state, db, %RedisCommand.ZRemRangeByLex{key: key, min: min, max: max}) do
    ZSets.zremrangebylex(state.store, db, key, min, max)
  end

  defp do_handle_command(state, db, %RedisCommand.ZUnionStore{
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

  defp do_handle_command(state, db, %RedisCommand.ZInterStore{
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

  defp do_handle_command(state, db, %RedisCommand.Del{keys: keys}) do
    Enum.reduce(keys, state.store, fn key, store ->
      Common.del(store, db, key)
    end)
  end

  defp do_handle_command(state, _db, %RedisCommand.PExpireAt{}) do
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
