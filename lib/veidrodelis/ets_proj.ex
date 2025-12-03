defmodule Vdr.ETSProj do
  @moduledoc """
  ETS-based Redis replication stream processor with typed stores.

  This module provides the core implementation for processing Redis replication streams
  with automatic key type tracking and routing to specialized stores.
  """

  require Logger

  @behaviour Vdr.RedisStream.Callback

  alias Vdr.Command
  alias Vdr.ETSProj.Write
  alias Vdr.ETSProj.Read

  defstruct [
    :id,
    :decoder,
    :shared_table,
    :write_strings,
    :write_sets,
    :write_hashes,
    :write_zsets,
    :write_lists,
    :decode_key
  ]

  @type id :: term()
  @type key :: binary()
  @type value :: binary()

  @type t :: %__MODULE__{
          id: id(),
          decoder: module(),
          shared_table: :ets.tid(),
          write_strings: Write.Strings.t(),
          write_sets: Write.Sets.t(),
          write_hashes: Write.Hashes.t(),
          write_zsets: Write.ZSets.t(),
          write_lists: Write.Lists.t(),
          decode_key: function()
        }

  # Public API

  @doc """
  Starts an ETSProj instance that connects to Redis and processes replication stream.

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
  Stops an ETSProj instance.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid)
  end

  @doc """
  Gets the current replication state of an ETSProj instance.
  """
  @spec get_replication_state(pid()) :: atom()
  def get_replication_state(pid) when is_pid(pid) do
    Vdr.RedisStream.Replica.get_replication_state(pid)
  end

  # RedisStream.Callback implementation

  @impl Vdr.RedisStream.Callback
  def on_replication_start(%__MODULE__{} = state) do
    reinitialize_state(state)
  end

  def on_replication_start(init_opts) do
    initialize_state(init_opts)
  end

  @impl Vdr.RedisStream.Callback
  def on_command(%__MODULE__{} = state, db, command) do
    case handle_command(state, db, command) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Vdr.RedisStream.Callback
  def on_destroy(%__MODULE__{} = state) do
    try do
      destroy_stores(state)
    rescue
      ArgumentError -> :ok
    end

    Vdr.Registry.unregister(state.id)

    :ok
  end

  def on_destroy(_state) do
    :ok
  end

  # Private functions

  defp initialize_state(%{id: id, decoder: decoder}) do
    cleanup_fun = fn ->
      :ets.delete(:veidrodelis_registry, id)
    end

    case Vdr.Registry.register(id, self(), cleanup_fun) do
      :ok ->
        shared_table = :ets.new(:vdr_store, [:ordered_set, :protected])

        decode_key_fun = get_decode_key_fun(decoder)

        # Create write stores with decode functions
        write_strings = Write.Strings.new(shared_table, decode_string_value_fun(decoder))
        write_sets = Write.Sets.new(shared_table, decode_set_entry_fun(decoder))

        write_hashes =
          Write.Hashes.new(
            shared_table,
            decode_hash_hkey_fun(decoder),
            decode_hash_entry_fun(decoder)
          )

        write_zsets = Write.ZSets.new(shared_table, decode_zset_entry_fun(decoder))
        write_lists = Write.Lists.new(shared_table, decode_list_entry_fun(decoder))

        # Create read stores without decode functions
        read_strings = Read.Strings.new(shared_table)
        read_sets = Read.Sets.new(shared_table)
        read_hashes = Read.Hashes.new(shared_table)
        read_zsets = Read.ZSets.new(shared_table)
        read_lists = Read.Lists.new(shared_table)

        # Register read stores in global registry
        stores = %{
          strings: read_strings,
          sets: read_sets,
          hashes: read_hashes,
          zsets: read_zsets,
          lists: read_lists,
          replica: self()
        }
        :ets.insert(:veidrodelis_registry, {id, stores})

        state = %__MODULE__{
          id: id,
          decoder: decoder,
          shared_table: shared_table,
          write_strings: write_strings,
          write_sets: write_sets,
          write_hashes: write_hashes,
          write_zsets: write_zsets,
          write_lists: write_lists,
          decode_key: decode_key_fun
        }

        {:ok, state}

      {:error, reason} ->
        {:error, {:registry_register_failed, reason}}
    end
  end

  defp reinitialize_state(%__MODULE__{id: id, decoder: decoder} = state) do
    destroy_stores(state)
    Vdr.Registry.unregister(id)
    initialize_state(%{id: id, decoder: decoder})
  end

  defp destroy_stores(%__MODULE__{} = state) do
    :ets.delete(state.shared_table)
    :ok
  end

  # Command handlers

  defp handle_command(state, db, %Command.Set{key: raw_key, value: raw_value}) do
    decoded_key = state.decode_key.(raw_key)
    Write.Strings.set(state.write_strings, db, decoded_key, raw_value)
  end

  defp handle_command(state, db, %Command.MSet{pairs: pairs}) do
    decoded_pairs =
      Enum.map(pairs, fn {raw_key, raw_value} ->
        {state.decode_key.(raw_key), raw_value}
      end)

    Write.Strings.mset(state.write_strings, db, decoded_pairs)
  end

  defp handle_command(state, db, %Command.Append{key: raw_key, value: raw_value}) do
    decoded_key = state.decode_key.(raw_key)
    Write.Strings.append(state.write_strings, db, decoded_key, raw_value)
  end

  defp handle_command(state, db, %Command.SetRange{key: raw_key, offset: offset, value: raw_value}) do
    decoded_key = state.decode_key.(raw_key)
    Write.Strings.setrange(state.write_strings, db, decoded_key, offset, raw_value)
  end

  defp handle_command(state, db, %Command.SetBit{key: raw_key, offset: offset, value: bit}) do
    decoded_key = state.decode_key.(raw_key)
    Write.Strings.setbit(state.write_strings, db, decoded_key, offset, bit)
  end

  # List commands
  defp handle_command(state, db, %Command.RPush{key: raw_key, values: values}) do
    decoded_key = state.decode_key.(raw_key)
    Write.Lists.rpush(state.write_lists, db, decoded_key, values)
  end

  defp handle_command(state, db, %Command.LPush{key: raw_key, values: values}) do
    decoded_key = state.decode_key.(raw_key)
    Write.Lists.lpush(state.write_lists, db, decoded_key, values)
  end

  defp handle_command(state, db, %Command.RPushX{key: raw_key, values: values}) do
    decoded_key = state.decode_key.(raw_key)
    Write.Lists.rpushx(state.write_lists, db, decoded_key, values)
  end

  defp handle_command(state, db, %Command.LPushX{key: raw_key, values: values}) do
    decoded_key = state.decode_key.(raw_key)
    Write.Lists.lpushx(state.write_lists, db, decoded_key, values)
  end

  defp handle_command(state, db, %Command.LPop{key: raw_key}) do
    decoded_key = state.decode_key.(raw_key)
    Write.Lists.lpop(state.write_lists, db, decoded_key)
  end

  defp handle_command(state, db, %Command.RPop{key: raw_key}) do
    decoded_key = state.decode_key.(raw_key)
    Write.Lists.rpop(state.write_lists, db, decoded_key)
  end

  defp handle_command(state, db, %Command.LRem{key: raw_key, count: count, value: value}) do
    decoded_key = state.decode_key.(raw_key)
    Write.Lists.lrem(state.write_lists, db, decoded_key, count, value)
  end

  defp handle_command(state, db, %Command.LTrim{key: raw_key, start: start_idx, stop: stop_idx}) do
    decoded_key = state.decode_key.(raw_key)
    Write.Lists.ltrim(state.write_lists, db, decoded_key, start_idx, stop_idx)
  end

  defp handle_command(state, db, %Command.LSet{key: raw_key, index: index, value: value}) do
    decoded_key = state.decode_key.(raw_key)
    Write.Lists.lset(state.write_lists, db, decoded_key, index, value)
  end

  defp handle_command(
        state,
        db,
        %Command.LInsert{key: raw_key, before_after: position, pivot: pivot, element: element}
      ) do
    decoded_key = state.decode_key.(raw_key)
    Write.Lists.linsert(state.write_lists, db, decoded_key, position, pivot, element)
  end

  defp handle_command(state, db, %Command.RPopLPush{source: raw_source, destination: raw_dest}) do
    decoded_source = state.decode_key.(raw_source)
    decoded_dest = state.decode_key.(raw_dest)
    Write.Lists.rpoplpush(state.write_lists, db, decoded_source, decoded_dest)
  end

  defp handle_command(state, db, %Command.SAdd{key: raw_key, members: members}) do
    decoded_key = state.decode_key.(raw_key)
    Write.Sets.sadd(state.write_sets, db, decoded_key, members)
  end

  defp handle_command(state, db, %Command.SRem{key: raw_key, members: members}) do
    decoded_key = state.decode_key.(raw_key)
    Write.Sets.srem(state.write_sets, db, decoded_key, members)
  end

  defp handle_command(state, db, %Command.SMove{
         source: raw_source,
         destination: raw_dest,
         member: member
       }) do
    decoded_source = state.decode_key.(raw_source)
    decoded_dest = state.decode_key.(raw_dest)
    Write.Sets.smove(state.write_sets, db, decoded_source, decoded_dest, member)
  end

  defp handle_command(state, db, %Command.SInterStore{destination: raw_dest, keys: raw_keys}) do
    decoded_dest = state.decode_key.(raw_dest)
    decoded_keys = Enum.map(raw_keys, &state.decode_key.(&1))
    Write.Sets.sinterstore(state.write_sets, db, decoded_dest, decoded_keys)
  end

  defp handle_command(state, db, %Command.SUnionStore{destination: raw_dest, keys: raw_keys}) do
    decoded_dest = state.decode_key.(raw_dest)
    decoded_keys = Enum.map(raw_keys, &state.decode_key.(&1))
    Write.Sets.sunionstore(state.write_sets, db, decoded_dest, decoded_keys)
  end

  defp handle_command(state, db, %Command.SDiffStore{destination: raw_dest, keys: raw_keys}) do
    decoded_dest = state.decode_key.(raw_dest)
    decoded_keys = Enum.map(raw_keys, &state.decode_key.(&1))
    Write.Sets.sdiffstore(state.write_sets, db, decoded_dest, decoded_keys)
  end

  defp handle_command(state, db, %Command.HSet{key: raw_key, fields: field_values}) do
    decoded_key = state.decode_key.(raw_key)
    Write.Hashes.hset(state.write_hashes, db, decoded_key, field_values)
  end

  defp handle_command(state, db, %Command.HDel{key: raw_key, fields: fields}) do
    decoded_key = state.decode_key.(raw_key)
    Write.Hashes.hdel(state.write_hashes, db, decoded_key, fields)
  end

  defp handle_command(state, db, %Command.ZAdd{key: raw_key, members: members}) do
    decoded_key = state.decode_key.(raw_key)
    Write.ZSets.zadd(state.write_zsets, db, decoded_key, members)
  end

  defp handle_command(state, db, %Command.ZRem{key: raw_key, members: members}) do
    decoded_key = state.decode_key.(raw_key)
    Write.ZSets.zrem(state.write_zsets, db, decoded_key, members)
  end

  defp handle_command(state, db, %Command.ZPopMax{key: raw_key, count: count}) do
    decoded_key = state.decode_key.(raw_key)
    Write.ZSets.zpopmax(state.write_zsets, db, decoded_key, count)
    :ok
  end

  defp handle_command(state, db, %Command.ZPopMin{key: raw_key, count: count}) do
    decoded_key = state.decode_key.(raw_key)
    Write.ZSets.zpopmin(state.write_zsets, db, decoded_key, count)
    :ok
  end

  defp handle_command(state, db, %Command.ZRemRangeByRank{
         key: raw_key,
         start: start_idx,
         stop: stop_idx
       }) do
    decoded_key = state.decode_key.(raw_key)
    Write.ZSets.zremrangebyrank(state.write_zsets, db, decoded_key, start_idx, stop_idx)
  end

  defp handle_command(state, db, %Command.ZRemRangeByScore{key: raw_key, min: min, max: max}) do
    decoded_key = state.decode_key.(raw_key)
    min_score = parse_score(min)
    max_score = parse_score(max)
    Write.ZSets.zremrangebyscore(state.write_zsets, db, decoded_key, min_score, max_score)
  end

  defp handle_command(state, db, %Command.ZRemRangeByLex{key: raw_key, min: min, max: max}) do
    decoded_key = state.decode_key.(raw_key)
    Write.ZSets.zremrangebylex(state.write_zsets, db, decoded_key, min, max)
  end

  defp handle_command(state, db, %Command.ZUnionStore{
         destination: raw_dest,
         keys: raw_keys,
         weights: weights,
         aggregate: aggregate
       }) do
    decoded_dest = state.decode_key.(raw_dest)
    decoded_keys = Enum.map(raw_keys, &state.decode_key.(&1))

    Write.ZSets.zunionstore(
      state.write_zsets,
      db,
      decoded_dest,
      decoded_keys,
      weights || [],
      aggregate || :sum
    )
  end

  defp handle_command(state, db, %Command.ZInterStore{
         destination: raw_dest,
         keys: raw_keys,
         weights: weights,
         aggregate: aggregate
       }) do
    decoded_dest = state.decode_key.(raw_dest)
    decoded_keys = Enum.map(raw_keys, &state.decode_key.(&1))

    Write.ZSets.zinterstore(
      state.write_zsets,
      db,
      decoded_dest,
      decoded_keys,
      weights || [],
      aggregate || :sum
    )
  end

  defp handle_command(state, db, %Command.Del{keys: keys}) do
    Enum.each(keys, fn raw_key ->
      delete_key(state, db, raw_key)
    end)

    :ok
  end

  defp handle_command(_state, _db, %Command.PExpireAt{}) do
    :ok
  end

  defp handle_command(_state, _db, _command) do
    :ok
  end

  defp delete_key(state, db, raw_key) do
    decoded_key = state.decode_key.(raw_key)
    Write.Common.del(state.shared_table, db, decoded_key)
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
      Logger.debug("decode_list_entry_fun is exported from #{inspect(decoder)}")
      &decoder.decode_list_entry/2
    else
      Logger.debug("decode_list_entry_fun is not exported from #{inspect(decoder)}, using identity2")
      Logger.debug("decoder: #{inspect(decoder.module_info(:exports))}")
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
