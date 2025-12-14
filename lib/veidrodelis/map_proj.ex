defmodule Vdr.MapProj do
  @moduledoc """
  Map-based Redis replication stream processor with typed stores.

  This module provides the core implementation for processing Redis replication streams
  with automatic key type tracking and routing to specialized stores, all using pure Elixir maps.
  """

  require Logger

  @behaviour Vdr.RedisStream.Callback

  alias Vdr.Command
  alias Vdr.MapProj.{Strings, Lists, Sets, Hashes, ZSets, Common}

  defstruct [
    :id,
    :decoder,
    :strings_config,
    :sets_config,
    :hashes_config,
    :zsets_config,
    :lists_config,
    :decode_key,
    :store
  ]

  @type id :: term()
  @type key :: binary()
  @type value :: binary()

  @type t :: %__MODULE__{
          id: id(),
          decoder: module(),
          strings_config: Strings.t(),
          sets_config: Sets.t(),
          hashes_config: Hashes.t(),
          zsets_config: ZSets.t(),
          lists_config: Lists.t(),
          decode_key: function(),
          store: map()
        }

  # Public API

  @doc """
  Starts a MapProj instance that connects to Redis and processes replication stream.

  ## Options

    * `:id` - Required. Unique identifier for this instance
    * `:decoder` - Required. Module implementing the Veidrodelis decoder behaviour
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
    id = Keyword.fetch!(opts, :id)
    decoder = Keyword.fetch!(opts, :decoder)

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
        :max_reconnect_delay_ms
      ])

    initial_state = %{id: id, decoder: decoder}

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
    dbg(command)
    new_store = do_handle_command(state, db, command)
    {:ok, %{state | store: new_store}}
  end

  @impl Vdr.RedisStream.Callback
  def handle_call(%__MODULE__{} = state, message) do
    case message do
      {:get, db, key} ->
        result = Strings.get(state.store, db, key)
        {:reply, result, state}

      {:get_decoded, db, key} ->
        result = Strings.get_decoded(state.store, db, key)
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

  defp initialize_state(%{id: id, decoder: decoder}) do
    decode_key_fun = get_decode_key_fun(decoder)

    # Create store configs with decode functions
    strings_config = Strings.new(decode_string_value_fun(decoder))
    sets_config = Sets.new(decode_set_entry_fun(decoder))

    hashes_config =
      Hashes.new(
        decode_hash_hkey_fun(decoder),
        decode_hash_entry_fun(decoder)
      )

    zsets_config = ZSets.new(decode_zset_entry_fun(decoder))
    lists_config = Lists.new(decode_list_entry_fun(decoder))

    state = %__MODULE__{
      id: id,
      decoder: decoder,
      strings_config: strings_config,
      sets_config: sets_config,
      hashes_config: hashes_config,
      zsets_config: zsets_config,
      lists_config: lists_config,
      decode_key: decode_key_fun,
      store: %{}
    }

    {:ok, state}
  end

  defp reinitialize_state(%__MODULE__{id: id, decoder: decoder}) do
    initialize_state(%{id: id, decoder: decoder})
  end

  # Command handlers

  defp do_handle_command(state, db, %Command.Set{key: raw_key, value: raw_value}) do
    decoded_key = state.decode_key.(raw_key)
    Strings.set(state.store, state.strings_config, db, decoded_key, raw_value)
  end

  defp do_handle_command(state, db, %Command.MSet{pairs: pairs}) do
    decoded_pairs =
      Enum.map(pairs, fn {raw_key, raw_value} ->
        {state.decode_key.(raw_key), raw_value}
      end)

    Strings.mset(state.store, state.strings_config, db, decoded_pairs)
  end

  defp do_handle_command(state, db, %Command.Append{key: raw_key, value: raw_value}) do
    decoded_key = state.decode_key.(raw_key)
    Strings.append(state.store, state.strings_config, db, decoded_key, raw_value)
  end

  defp do_handle_command(state, db, %Command.SetRange{
         key: raw_key,
         offset: offset,
         value: raw_value
       }) do
    decoded_key = state.decode_key.(raw_key)
    Strings.setrange(state.store, state.strings_config, db, decoded_key, offset, raw_value)
  end

  defp do_handle_command(state, db, %Command.SetBit{key: raw_key, offset: offset, value: bit}) do
    decoded_key = state.decode_key.(raw_key)
    Strings.setbit(state.store, state.strings_config, db, decoded_key, offset, bit)
  end

  # List commands
  defp do_handle_command(state, db, %Command.RPush{key: raw_key, values: values}) do
    decoded_key = state.decode_key.(raw_key)
    Lists.rpush(state.store, state.lists_config, db, decoded_key, values)
  end

  defp do_handle_command(state, db, %Command.LPush{key: raw_key, values: values}) do
    decoded_key = state.decode_key.(raw_key)
    Lists.lpush(state.store, state.lists_config, db, decoded_key, values)
  end

  defp do_handle_command(state, db, %Command.RPushX{key: raw_key, values: values}) do
    decoded_key = state.decode_key.(raw_key)
    Lists.rpushx(state.store, state.lists_config, db, decoded_key, values)
  end

  defp do_handle_command(state, db, %Command.LPushX{key: raw_key, values: values}) do
    decoded_key = state.decode_key.(raw_key)
    Lists.lpushx(state.store, state.lists_config, db, decoded_key, values)
  end

  defp do_handle_command(state, db, %Command.LPop{key: raw_key}) do
    decoded_key = state.decode_key.(raw_key)
    Lists.lpop(state.store, db, decoded_key)
  end

  defp do_handle_command(state, db, %Command.RPop{key: raw_key}) do
    decoded_key = state.decode_key.(raw_key)
    Lists.rpop(state.store, db, decoded_key)
  end

  defp do_handle_command(state, db, %Command.LRem{key: raw_key, count: count, value: value}) do
    decoded_key = state.decode_key.(raw_key)
    Lists.lrem(state.store, state.lists_config, db, decoded_key, count, value)
  end

  defp do_handle_command(state, db, %Command.LTrim{
         key: raw_key,
         start: start_idx,
         stop: stop_idx
       }) do
    decoded_key = state.decode_key.(raw_key)
    Lists.ltrim(state.store, db, decoded_key, start_idx, stop_idx)
  end

  defp do_handle_command(state, db, %Command.LSet{key: raw_key, index: index, value: value}) do
    decoded_key = state.decode_key.(raw_key)
    Lists.lset(state.store, state.lists_config, db, decoded_key, index, value)
  end

  defp do_handle_command(
        state,
        db,
        %Command.LInsert{key: raw_key, before_after: position, pivot: pivot, element: element}
      ) do
    decoded_key = state.decode_key.(raw_key)
    Lists.linsert(state.store, state.lists_config, db, decoded_key, position, pivot, element)
  end

  defp do_handle_command(state, db, %Command.RPopLPush{
         source: raw_source,
         destination: raw_dest
       }) do
    decoded_source = state.decode_key.(raw_source)
    decoded_dest = state.decode_key.(raw_dest)
    Lists.rpoplpush(state.store, db, decoded_source, decoded_dest)
  end

  defp do_handle_command(state, db, %Command.SAdd{key: raw_key, members: members}) do
    decoded_key = state.decode_key.(raw_key)
    Sets.sadd(state.store, state.sets_config, db, decoded_key, members)
  end

  defp do_handle_command(state, db, %Command.SRem{key: raw_key, members: members}) do
    decoded_key = state.decode_key.(raw_key)
    Sets.srem(state.store, state.sets_config, db, decoded_key, members)
  end

  defp do_handle_command(state, db, %Command.SMove{
         source: raw_source,
         destination: raw_dest,
         member: member
       }) do
    decoded_source = state.decode_key.(raw_source)
    decoded_dest = state.decode_key.(raw_dest)
    Sets.smove(state.store, state.sets_config, db, decoded_source, decoded_dest, member)
  end

  defp do_handle_command(state, db, %Command.SInterStore{destination: raw_dest, keys: raw_keys}) do
    decoded_dest = state.decode_key.(raw_dest)
    decoded_keys = Enum.map(raw_keys, &state.decode_key.(&1))
    Sets.sinterstore(state.store, state.sets_config, db, decoded_dest, decoded_keys)
  end

  defp do_handle_command(state, db, %Command.SUnionStore{destination: raw_dest, keys: raw_keys}) do
    decoded_dest = state.decode_key.(raw_dest)
    decoded_keys = Enum.map(raw_keys, &state.decode_key.(&1))
    Sets.sunionstore(state.store, state.sets_config, db, decoded_dest, decoded_keys)
  end

  defp do_handle_command(state, db, %Command.SDiffStore{destination: raw_dest, keys: raw_keys}) do
    decoded_dest = state.decode_key.(raw_dest)
    decoded_keys = Enum.map(raw_keys, &state.decode_key.(&1))
    Sets.sdiffstore(state.store, state.sets_config, db, decoded_dest, decoded_keys)
  end

  defp do_handle_command(state, db, %Command.HSet{key: raw_key, fields: field_values}) do
    decoded_key = state.decode_key.(raw_key)
    Hashes.hset(state.store, state.hashes_config, db, decoded_key, field_values)
  end

  defp do_handle_command(state, db, %Command.HDel{key: raw_key, fields: fields}) do
    decoded_key = state.decode_key.(raw_key)
    Hashes.hdel(state.store, state.hashes_config, db, decoded_key, fields)
  end

  defp do_handle_command(state, db, %Command.ZAdd{key: raw_key, members: members}) do
    decoded_key = state.decode_key.(raw_key)
    ZSets.zadd(state.store, state.zsets_config, db, decoded_key, members)
  end

  defp do_handle_command(state, db, %Command.ZRem{key: raw_key, members: members}) do
    decoded_key = state.decode_key.(raw_key)
    ZSets.zrem(state.store, state.zsets_config, db, decoded_key, members)
  end

  defp do_handle_command(state, db, %Command.ZPopMax{key: raw_key, count: count}) do
    decoded_key = state.decode_key.(raw_key)
    ZSets.zpopmax(state.store, db, decoded_key, count)
  end

  defp do_handle_command(state, db, %Command.ZPopMin{key: raw_key, count: count}) do
    decoded_key = state.decode_key.(raw_key)
    ZSets.zpopmin(state.store, db, decoded_key, count)
  end

  defp do_handle_command(state, db, %Command.ZRemRangeByRank{
         key: raw_key,
         start: start_idx,
         stop: stop_idx
       }) do
    decoded_key = state.decode_key.(raw_key)
    ZSets.zremrangebyrank(state.store, db, decoded_key, start_idx, stop_idx)
  end

  defp do_handle_command(state, db, %Command.ZRemRangeByScore{key: raw_key, min: min, max: max}) do
    decoded_key = state.decode_key.(raw_key)
    min_score = parse_score(min)
    max_score = parse_score(max)
    ZSets.zremrangebyscore(state.store, db, decoded_key, min_score, max_score)
  end

  defp do_handle_command(state, db, %Command.ZRemRangeByLex{key: raw_key, min: min, max: max}) do
    decoded_key = state.decode_key.(raw_key)
    ZSets.zremrangebylex(state.store, db, decoded_key, min, max)
  end

  defp do_handle_command(state, db, %Command.ZUnionStore{
         destination: raw_dest,
         keys: raw_keys,
         weights: weights,
         aggregate: aggregate
       }) do
    decoded_dest = state.decode_key.(raw_dest)
    decoded_keys = Enum.map(raw_keys, &state.decode_key.(&1))

    ZSets.zunionstore(
      state.store,
      db,
      decoded_dest,
      decoded_keys,
      weights || [],
      aggregate || :sum
    )
  end

  defp do_handle_command(state, db, %Command.ZInterStore{
         destination: raw_dest,
         keys: raw_keys,
         weights: weights,
         aggregate: aggregate
       }) do
    decoded_dest = state.decode_key.(raw_dest)
    decoded_keys = Enum.map(raw_keys, &state.decode_key.(&1))

    ZSets.zinterstore(
      state.store,
      db,
      decoded_dest,
      decoded_keys,
      weights || [],
      aggregate || :sum
    )
  end

  defp do_handle_command(state, db, %Command.Del{keys: keys}) do
    Enum.reduce(keys, state.store, fn raw_key, store ->
      decoded_key = state.decode_key.(raw_key)
      Common.del(store, db, decoded_key)
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

  # Decoder wrapper functions

  defp get_decode_key_fun(decoder) do
    if eager_function_exported?(decoder, :decode_key, 1) do
      &decoder.decode_key/1
    else
      &identity/1
    end
  end

  defp decode_string_value_fun(decoder) do
    if eager_function_exported?(decoder, :decode_string_value, 2) do
      &decoder.decode_string_value/2
    else
      &identity2/2
    end
  end

  defp decode_set_entry_fun(decoder) do
    if eager_function_exported?(decoder, :decode_set_entry, 2) do
      &decoder.decode_set_entry/2
    else
      &identity2/2
    end
  end

  defp decode_hash_hkey_fun(decoder) do
    if eager_function_exported?(decoder, :decode_hash_hkey, 2) do
      &decoder.decode_hash_hkey/2
    else
      &identity2/2
    end
  end

  defp decode_hash_entry_fun(decoder) do
    if eager_function_exported?(decoder, :decode_hash_entry, 3) do
      &decoder.decode_hash_entry/3
    else
      &identity3/3
    end
  end

  defp decode_zset_entry_fun(decoder) do
    if eager_function_exported?(decoder, :decode_zset_entry, 2) do
      &decoder.decode_zset_entry/2
    else
      &identity2/2
    end
  end

  defp decode_list_entry_fun(decoder) do
    if eager_function_exported?(decoder, :decode_list_entry, 2) do
      &decoder.decode_list_entry/2
    else
      &identity2/2
    end
  end

  defp identity(a), do: a

  defp identity2(_a, b), do: b

  defp identity3(_a, _b, c), do: c

  defp eager_function_exported?(module, function, arity) do
    Code.ensure_loaded!(module)
    function_exported?(module, function, arity)
  end
end
