defmodule Veidrodelis do
  @moduledoc """
  Veidrodelis - Redis replication stream processor with typed stores.

  This module provides a main interface for processing Redis replication streams
  with automatic key type tracking and routing to specialized stores.

  ## Features

    * Type-aware key routing
    * Automatic key type conflict resolution
    * Pluggable decoder modules for custom data transformations
    * ETS-backed stores for strings, lists, sets, hashes, and sorted sets
    * Process-based supervision for fault tolerance

  ## Decoder Behaviour

  Implement the `Veidrodelis` behaviour to define how keys and values are decoded:

      defmodule MyDecoder do
        @behaviour Veidrodelis

        @impl true
        def decode_string_key(key), do: key

        @impl true
        def decode_string_value(_key, value), do: Jason.decode!(value)

        # Implement other callbacks...
      end

  ## Usage

      # Start a Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(
        id: :my_instance,
        decoder: MyDecoder,
        redis_opts: [host: "localhost", port: 6379]
      )

      # Access stores
      string_store = Veidrodelis.strings(:my_instance)
      set_store = Veidrodelis.sets(:my_instance)

      # Query data
      value = Veidrodelis.StringStore.get(string_store, 0, "mykey")
  """

  @behaviour Veidrodelis.RedisStream.Callback

  alias Veidrodelis.{StringStore, ListStore, SetStore, HashStore, ZsetStore, Command}

  defstruct [
    :id,
    :decoder,
    :key_registry,
    :strings,
    :lists,
    :sets,
    :hashes,
    :zsets,
    :decoder_funs
  ]

  @type id :: term()
  @type key :: binary()
  @type value :: binary()
  @type string_key :: any()
  @type set_key :: any()
  @type list_key :: any()
  @type hash_key :: any()
  @type hash_hkey :: any()
  @type zset_key :: any()

  @type decoder_funs :: %{
          string_key: boolean(),
          string_value: boolean(),
          set_key: boolean(),
          set_entry: boolean(),
          list_key: boolean(),
          list_entry: boolean(),
          hash_key: boolean(),
          hash_hkey: boolean(),
          hash_entry: boolean(),
          zset_key: boolean(),
          zset_entry: boolean()
        }

  @type t :: %__MODULE__{
          id: id(),
          decoder: module(),
          key_registry: :ets.tid(),
          strings: StringStore.t(),
          lists: ListStore.t(),
          sets: SetStore.t(),
          hashes: HashStore.t(),
          zsets: ZsetStore.t(),
          decoder_funs: decoder_funs()
        }

  # Behaviour callbacks for decoders

  @doc """
  Decodes a string key from its binary representation.
  """
  @callback decode_string_key(key()) :: string_key()

  @doc """
  Decodes a string value given the decoded key.
  """
  @callback decode_string_value(string_key(), value()) :: term()

  @doc """
  Decodes a set key from its binary representation.
  """
  @callback decode_set_key(key()) :: set_key()

  @doc """
  Decodes a set member given the decoded key.
  """
  @callback decode_set_entry(set_key(), value()) :: term()

  @doc """
  Decodes a list key from its binary representation.
  """
  @callback decode_list_key(key()) :: list_key()

  @doc """
  Decodes a list entry given the decoded key.
  """
  @callback decode_list_entry(list_key(), value()) :: term()

  @doc """
  Decodes a hash key from its binary representation.
  """
  @callback decode_hash_key(key()) :: hash_key()

  @doc """
  Decodes a hash field key given the decoded hash key.
  """
  @callback decode_hash_hkey(hash_key(), value()) :: hash_hkey()

  @doc """
  Decodes a hash entry value given the decoded hash key and field key.
  """
  @callback decode_hash_entry(hash_key(), hash_hkey(), value()) :: term()

  @doc """
  Decodes a sorted set key from its binary representation.
  """
  @callback decode_zset_key(key()) :: zset_key()

  @doc """
  Decodes a sorted set member given the decoded key.
  """
  @callback decode_zset_entry(zset_key(), value()) :: term()

  @optional_callbacks decode_string_key: 1,
                      decode_string_value: 2,
                      decode_set_key: 1,
                      decode_set_entry: 2,
                      decode_list_key: 1,
                      decode_list_entry: 2,
                      decode_hash_key: 1,
                      decode_hash_hkey: 2,
                      decode_hash_entry: 3,
                      decode_zset_key: 1,
                      decode_zset_entry: 2

  # Public API

  @doc """
  Starts a Veidrodelis instance that connects to Redis and processes replication stream.

  ## Options

    * `:id` - Required. Unique identifier for this Veidrodelis instance
    * `:decoder` - Optional. Module implementing the Veidrodelis decoder behaviour (default: DefaultDecoder)
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

    * `{:ok, pid}` - Successfully started
    * `{:error, reason}` - Failed to start

  ## Example

      opts = [
        id: :my_instance,
        decoder: MyDecoder,
        host: "localhost",
        port: 6379
      ]

      {:ok, pid} = Veidrodelis.start_link(opts)

      # Access stores
      string_store = Veidrodelis.strings(:my_instance)
      value = Veidrodelis.StringStore.get_decoded(string_store, 0, "mykey")

      # Stop when done
      Veidrodelis.stop(pid)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    decoder = Keyword.get(opts, :decoder, DefaultDecoder)

    # Extract redis connection options
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

    # Build replica options with Veidrodelis as callback
    replica_opts =
      [
        callback_module: __MODULE__,
        callback_state: {id, decoder}
      ] ++ redis_opts

    Veidrodelis.RedisStream.Replica.start_link(replica_opts)
  end

  @doc """
  Stops a running Veidrodelis instance.

  This will terminate the replication connection and call the `on_destroy` callback
  to clean up stores and resources.

  ## Parameters

    * `server` - The PID or name of the Veidrodelis instance to stop

  ## Returns

    * `:ok`

  ## Example

      {:ok, pid} = Veidrodelis.start_link(id: :my_instance, host: "localhost")
      # ... use the instance ...
      Veidrodelis.stop(pid)
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    Veidrodelis.RedisStream.Replica.stop(server)
  end

  # RedisStream.Callback implementation

  @impl Veidrodelis.RedisStream.Callback
  def on_replication_start(%__MODULE__{} = state) do
    # Reinitialize with existing ID and decoder
    new_state = reinitialize_state(state)
    {:ok, new_state}
  end

  def on_replication_start({id, decoder}) when is_atom(decoder) do
    # Initialize new state with custom decoder
    state = initialize_state(id, decoder)
    {:ok, state}
  end

  def on_replication_start(id) do
    # Initialize new state with default decoder
    state = initialize_state(id, DefaultDecoder)
    {:ok, state}
  end

  @impl Veidrodelis.RedisStream.Callback
  def on_command(%__MODULE__{} = state, db, command) do
    case handle_command(state, db, command) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Veidrodelis.RedisStream.Callback
  def on_destroy(%__MODULE__{} = state) do
    # Destroy stores (may fail if tables are not owned by this process)
    try do
      destroy_stores(state)
    rescue
      ArgumentError -> :ok
    end

    # Deregister from global registry
    :ets.delete(:veidrodelis_registry, {state.id, :strings})
    :ets.delete(:veidrodelis_registry, {state.id, :lists})
    :ets.delete(:veidrodelis_registry, {state.id, :sets})
    :ets.delete(:veidrodelis_registry, {state.id, :hashes})
    :ets.delete(:veidrodelis_registry, {state.id, :zsets})

    # Delete key registry (may fail if not owned by this process)
    try do
      :ets.delete(state.key_registry)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # Store accessor functions

  @doc """
  Gets the string store for the given instance ID.
  """
  @spec strings(id()) :: StringStore.t()
  def strings(id) do
    lookup_store(id, :strings)
  end

  @doc """
  Gets the list store for the given instance ID.
  """
  @spec lists(id()) :: ListStore.t()
  def lists(id) do
    lookup_store(id, :lists)
  end

  @doc """
  Gets the set store for the given instance ID.
  """
  @spec sets(id()) :: SetStore.t()
  def sets(id) do
    lookup_store(id, :sets)
  end

  @doc """
  Gets the hash store for the given instance ID.
  """
  @spec hashes(id()) :: HashStore.t()
  def hashes(id) do
    lookup_store(id, :hashes)
  end

  @doc """
  Gets the sorted set store for the given instance ID.
  """
  @spec zsets(id()) :: ZsetStore.t()
  def zsets(id) do
    lookup_store(id, :zsets)
  end

  # Private functions

  defp initialize_state(id, decoder) do
    # Ensure registry table exists
    ensure_registry_table()

    # Create key registry table
    key_registry = :ets.new(:key_registry, [:set, :private])

    # Cache decoder function availability
    decoder_funs = %{
      string_key: function_exported?(decoder, :decode_string_key, 1),
      string_value: function_exported?(decoder, :decode_string_value, 2),
      set_key: function_exported?(decoder, :decode_set_key, 1),
      set_entry: function_exported?(decoder, :decode_set_entry, 2),
      list_key: function_exported?(decoder, :decode_list_key, 1),
      list_entry: function_exported?(decoder, :decode_list_entry, 2),
      hash_key: function_exported?(decoder, :decode_hash_key, 1),
      hash_hkey: function_exported?(decoder, :decode_hash_hkey, 2),
      hash_entry: function_exported?(decoder, :decode_hash_entry, 3),
      zset_key: function_exported?(decoder, :decode_zset_key, 1),
      zset_entry: function_exported?(decoder, :decode_zset_entry, 2)
    }

    # Create stores with decoder functions
    strings = StringStore.new(&decode_string_value(decoder, decoder_funs, &1, &2))
    lists = ListStore.new(decode_fun: &decode_list_entry(decoder, decoder_funs, &1, &2))
    sets = SetStore.new(&decode_set_entry(decoder, decoder_funs, &1, &2))

    hashes =
      HashStore.new(
        &decode_hash_hkey(decoder, decoder_funs, &1, &2),
        &decode_hash_entry(decoder, decoder_funs, &1, &2, &3)
      )

    zsets = ZsetStore.new(&decode_zset_entry(decoder, decoder_funs, &1, &2))

    # Register stores in global registry
    :ets.insert(:veidrodelis_registry, {{id, :strings}, strings})
    :ets.insert(:veidrodelis_registry, {{id, :lists}, lists})
    :ets.insert(:veidrodelis_registry, {{id, :sets}, sets})
    :ets.insert(:veidrodelis_registry, {{id, :hashes}, hashes})
    :ets.insert(:veidrodelis_registry, {{id, :zsets}, zsets})

    %__MODULE__{
      id: id,
      decoder: decoder,
      key_registry: key_registry,
      strings: strings,
      lists: lists,
      sets: sets,
      hashes: hashes,
      zsets: zsets,
      decoder_funs: decoder_funs
    }
  end

  defp reinitialize_state(%__MODULE__{id: id, decoder: decoder} = state) do
    # Destroy old stores
    destroy_stores(state)

    # Deregister from global registry
    :ets.delete(:veidrodelis_registry, {id, :strings})
    :ets.delete(:veidrodelis_registry, {id, :lists})
    :ets.delete(:veidrodelis_registry, {id, :sets})
    :ets.delete(:veidrodelis_registry, {id, :hashes})
    :ets.delete(:veidrodelis_registry, {id, :zsets})

    # Delete key registry
    :ets.delete(state.key_registry)

    # Create new state
    initialize_state(id, decoder)
  end

  defp destroy_stores(%__MODULE__{} = state) do
    StringStore.destroy(state.strings)
    ListStore.destroy(state.lists)
    SetStore.destroy(state.sets)
    HashStore.destroy(state.hashes)
    ZsetStore.destroy(state.zsets)
    :ok
  end

  defp ensure_registry_table do
    case :ets.whereis(:veidrodelis_registry) do
      :undefined ->
        :ets.new(:veidrodelis_registry, [:set, :public, :named_table])

      _ ->
        :ok
    end
  end

  defp lookup_store(id, type) do
    case :ets.lookup(:veidrodelis_registry, {id, type}) do
      [{{^id, ^type}, store}] -> store
      [] -> raise "No store registered for #{inspect(id)} / #{inspect(type)}"
    end
  end

  defp handle_command(state, db, %Command.Set{key: raw_key, value: raw_value}) do
    decoded_key = decode_string_key(state.decoder, state.decoder_funs, raw_key)
    handle_key_type_change(state, db, raw_key, :string)
    StringStore.set(state.strings, db, decoded_key, raw_value)
  end

  defp handle_command(state, db, %Command.MSet{pairs: pairs}) do
    Enum.each(pairs, fn {raw_key, _raw_value} ->
      handle_key_type_change(state, db, raw_key, :string)
    end)

    decoded_pairs =
      Enum.map(pairs, fn {raw_key, raw_value} ->
        {decode_string_key(state.decoder, state.decoder_funs, raw_key), raw_value}
      end)

    StringStore.mset(state.strings, db, decoded_pairs)
  end

  defp handle_command(state, db, %Command.Append{key: raw_key, value: raw_value}) do
    decoded_key = decode_string_key(state.decoder, state.decoder_funs, raw_key)
    handle_key_type_change(state, db, raw_key, :string)
    StringStore.append(state.strings, db, decoded_key, raw_value)
  end

  defp handle_command(state, db, %Command.SetRange{key: raw_key, offset: offset, value: raw_value}) do
    decoded_key = decode_string_key(state.decoder, state.decoder_funs, raw_key)
    handle_key_type_change(state, db, raw_key, :string)
    StringStore.setrange(state.strings, db, decoded_key, offset, raw_value)
  end

  defp handle_command(state, db, %Command.SetBit{key: raw_key, offset: offset, value: bit}) do
    decoded_key = decode_string_key(state.decoder, state.decoder_funs, raw_key)
    handle_key_type_change(state, db, raw_key, :string)
    StringStore.setbit(state.strings, db, decoded_key, offset, bit)
  end

  defp handle_command(state, db, %Command.RPush{key: raw_key, values: values}) do
    handle_key_type_change(state, db, raw_key, :list)
    decoded_key = decode_list_key(state.decoder, state.decoder_funs, raw_key)

    decoded_values =
      Enum.map(values, &decode_list_entry(state.decoder, state.decoder_funs, decoded_key, &1))

    ListStore.rpush(state.lists, db, decoded_key, decoded_values)
  end

  defp handle_command(state, db, %Command.LPush{key: raw_key, values: values}) do
    handle_key_type_change(state, db, raw_key, :list)
    decoded_key = decode_list_key(state.decoder, state.decoder_funs, raw_key)

    decoded_values =
      Enum.map(values, &decode_list_entry(state.decoder, state.decoder_funs, decoded_key, &1))

    ListStore.lpush(state.lists, db, decoded_key, decoded_values)
  end

  defp handle_command(state, db, %Command.RPushX{key: raw_key, values: values}) do
    decoded_key = decode_list_key(state.decoder, state.decoder_funs, raw_key)

    decoded_values =
      Enum.map(values, &decode_list_entry(state.decoder, state.decoder_funs, decoded_key, &1))

    ListStore.rpushx(state.lists, db, decoded_key, decoded_values)
  end

  defp handle_command(state, db, %Command.LPushX{key: raw_key, values: values}) do
    decoded_key = decode_list_key(state.decoder, state.decoder_funs, raw_key)

    decoded_values =
      Enum.map(values, &decode_list_entry(state.decoder, state.decoder_funs, decoded_key, &1))

    ListStore.lpushx(state.lists, db, decoded_key, decoded_values)
  end

  defp handle_command(state, db, %Command.LPop{key: raw_key}) do
    decoded_key = decode_list_key(state.decoder, state.decoder_funs, raw_key)
    ListStore.lpop(state.lists, db, decoded_key)
  end

  defp handle_command(state, db, %Command.RPop{key: raw_key}) do
    decoded_key = decode_list_key(state.decoder, state.decoder_funs, raw_key)
    ListStore.rpop(state.lists, db, decoded_key)
  end

  defp handle_command(state, db, %Command.LRem{key: raw_key, count: count, value: value}) do
    decoded_key = decode_list_key(state.decoder, state.decoder_funs, raw_key)
    decoded_value = decode_list_entry(state.decoder, state.decoder_funs, decoded_key, value)
    ListStore.lrem(state.lists, db, decoded_key, count, decoded_value)
  end

  defp handle_command(state, db, %Command.LTrim{key: raw_key, start: start_idx, stop: stop_idx}) do
    decoded_key = decode_list_key(state.decoder, state.decoder_funs, raw_key)
    ListStore.ltrim(state.lists, db, decoded_key, start_idx, stop_idx)
  end

  defp handle_command(state, db, %Command.LSet{key: raw_key, index: index, value: value}) do
    decoded_key = decode_list_key(state.decoder, state.decoder_funs, raw_key)
    decoded_value = decode_list_entry(state.decoder, state.decoder_funs, decoded_key, value)
    ListStore.lset(state.lists, db, decoded_key, index, decoded_value)
  end

  defp handle_command(state, db, %Command.LInsert{
         key: raw_key,
         before_after: position,
         pivot: pivot,
         element: element
       }) do
    decoded_key = decode_list_key(state.decoder, state.decoder_funs, raw_key)
    decoded_pivot = decode_list_entry(state.decoder, state.decoder_funs, decoded_key, pivot)
    decoded_element = decode_list_entry(state.decoder, state.decoder_funs, decoded_key, element)
    ListStore.linsert(state.lists, db, decoded_key, position, decoded_pivot, decoded_element)
  end

  defp handle_command(state, db, %Command.RPopLPush{source: raw_source, destination: raw_dest}) do
    decoded_source = decode_list_key(state.decoder, state.decoder_funs, raw_source)
    decoded_dest = decode_list_key(state.decoder, state.decoder_funs, raw_dest)
    ListStore.rpoplpush(state.lists, db, decoded_source, decoded_dest)
  end

  defp handle_command(state, db, %Command.SAdd{key: raw_key, members: members}) do
    handle_key_type_change(state, db, raw_key, :set)
    decoded_key = decode_set_key(state.decoder, state.decoder_funs, raw_key)
    SetStore.sadd(state.sets, db, decoded_key, members)
  end

  defp handle_command(state, db, %Command.SRem{key: raw_key, members: members}) do
    decoded_key = decode_set_key(state.decoder, state.decoder_funs, raw_key)
    SetStore.srem(state.sets, db, decoded_key, members)
  end

  defp handle_command(state, db, %Command.SMove{
         source: raw_source,
         destination: raw_dest,
         member: member
       }) do
    decoded_source = decode_set_key(state.decoder, state.decoder_funs, raw_source)
    decoded_dest = decode_set_key(state.decoder, state.decoder_funs, raw_dest)
    SetStore.smove(state.sets, db, decoded_source, decoded_dest, member)
  end

  defp handle_command(state, db, %Command.SInterStore{destination: raw_dest, keys: raw_keys}) do
    handle_key_type_change(state, db, raw_dest, :set)
    decoded_dest = decode_set_key(state.decoder, state.decoder_funs, raw_dest)
    decoded_keys = Enum.map(raw_keys, &decode_set_key(state.decoder, state.decoder_funs, &1))
    SetStore.sinterstore(state.sets, db, decoded_dest, decoded_keys)
  end

  defp handle_command(state, db, %Command.SUnionStore{destination: raw_dest, keys: raw_keys}) do
    handle_key_type_change(state, db, raw_dest, :set)
    decoded_dest = decode_set_key(state.decoder, state.decoder_funs, raw_dest)
    decoded_keys = Enum.map(raw_keys, &decode_set_key(state.decoder, state.decoder_funs, &1))
    SetStore.sunionstore(state.sets, db, decoded_dest, decoded_keys)
  end

  defp handle_command(state, db, %Command.SDiffStore{destination: raw_dest, keys: raw_keys}) do
    handle_key_type_change(state, db, raw_dest, :set)
    decoded_dest = decode_set_key(state.decoder, state.decoder_funs, raw_dest)
    decoded_keys = Enum.map(raw_keys, &decode_set_key(state.decoder, state.decoder_funs, &1))
    SetStore.sdiffstore(state.sets, db, decoded_dest, decoded_keys)
  end

  defp handle_command(state, db, %Command.HSet{key: raw_key, fields: field_values}) do
    handle_key_type_change(state, db, raw_key, :hash)
    decoded_key = decode_hash_key(state.decoder, state.decoder_funs, raw_key)
    HashStore.hset(state.hashes, db, decoded_key, field_values)
  end

  defp handle_command(state, db, %Command.HDel{key: raw_key, fields: fields}) do
    decoded_key = decode_hash_key(state.decoder, state.decoder_funs, raw_key)
    HashStore.hdel(state.hashes, db, decoded_key, fields)
  end

  defp handle_command(state, db, %Command.ZAdd{key: raw_key, members: members}) do
    handle_key_type_change(state, db, raw_key, :zset)
    decoded_key = decode_zset_key(state.decoder, state.decoder_funs, raw_key)
    ZsetStore.zadd(state.zsets, db, decoded_key, members)
  end

  defp handle_command(state, db, %Command.ZRem{key: raw_key, members: members}) do
    decoded_key = decode_zset_key(state.decoder, state.decoder_funs, raw_key)
    ZsetStore.zrem(state.zsets, db, decoded_key, members)
  end

  defp handle_command(state, db, %Command.ZPopMax{key: raw_key, count: count}) do
    decoded_key = decode_zset_key(state.decoder, state.decoder_funs, raw_key)
    ZsetStore.zpopmax(state.zsets, db, decoded_key, count)
    :ok
  end

  defp handle_command(state, db, %Command.ZPopMin{key: raw_key, count: count}) do
    decoded_key = decode_zset_key(state.decoder, state.decoder_funs, raw_key)
    ZsetStore.zpopmin(state.zsets, db, decoded_key, count)
    :ok
  end

  defp handle_command(state, db, %Command.ZRemRangeByRank{
         key: raw_key,
         start: start_idx,
         stop: stop_idx
       }) do
    decoded_key = decode_zset_key(state.decoder, state.decoder_funs, raw_key)
    ZsetStore.zremrangebyrank(state.zsets, db, decoded_key, start_idx, stop_idx)
  end

  defp handle_command(state, db, %Command.ZRemRangeByScore{key: raw_key, min: min, max: max}) do
    decoded_key = decode_zset_key(state.decoder, state.decoder_funs, raw_key)
    # Parse min/max from binary strings
    min_score = parse_score(min)
    max_score = parse_score(max)
    ZsetStore.zremrangebyscore(state.zsets, db, decoded_key, min_score, max_score)
  end

  defp handle_command(state, db, %Command.ZRemRangeByLex{key: raw_key, min: min, max: max}) do
    decoded_key = decode_zset_key(state.decoder, state.decoder_funs, raw_key)
    ZsetStore.zremrangebylex(state.zsets, db, decoded_key, min, max)
  end

  defp handle_command(state, db, %Command.ZUnionStore{
         destination: raw_dest,
         keys: raw_keys,
         weights: weights,
         aggregate: aggregate
       }) do
    handle_key_type_change(state, db, raw_dest, :zset)
    decoded_dest = decode_zset_key(state.decoder, state.decoder_funs, raw_dest)
    decoded_keys = Enum.map(raw_keys, &decode_zset_key(state.decoder, state.decoder_funs, &1))

    ZsetStore.zunionstore(
      state.zsets,
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
    handle_key_type_change(state, db, raw_dest, :zset)
    decoded_dest = decode_zset_key(state.decoder, state.decoder_funs, raw_dest)
    decoded_keys = Enum.map(raw_keys, &decode_zset_key(state.decoder, state.decoder_funs, &1))

    ZsetStore.zinterstore(
      state.zsets,
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
    # Ignore expiration commands for now
    :ok
  end

  defp handle_command(_state, _db, _command) do
    # Ignore unknown commands
    :ok
  end

  defp handle_key_type_change(state, db, raw_key, new_type) do
    registry_key = {db, raw_key}

    case :ets.lookup(state.key_registry, registry_key) do
      [] ->
        # New key, register it
        :ets.insert(state.key_registry, {registry_key, new_type})
        :ok

      [{^registry_key, ^new_type}] ->
        # Same type, no change needed
        :ok

      [{^registry_key, old_type}] ->
        # Type changed, delete from old store
        delete_from_store(state, db, raw_key, old_type)
        # Update registry
        :ets.insert(state.key_registry, {registry_key, new_type})
        :ok
    end
  end

  defp delete_from_store(state, db, raw_key, :string) do
    decoded_key = decode_string_key(state.decoder, state.decoder_funs, raw_key)
    StringStore.del(state.strings, db, decoded_key)
  end

  defp delete_from_store(state, db, raw_key, :list) do
    decoded_key = decode_list_key(state.decoder, state.decoder_funs, raw_key)
    ListStore.del(state.lists, db, decoded_key)
  end

  defp delete_from_store(state, db, raw_key, :set) do
    decoded_key = decode_set_key(state.decoder, state.decoder_funs, raw_key)
    SetStore.del(state.sets, db, decoded_key)
  end

  defp delete_from_store(state, db, raw_key, :hash) do
    decoded_key = decode_hash_key(state.decoder, state.decoder_funs, raw_key)
    HashStore.del(state.hashes, db, decoded_key)
  end

  defp delete_from_store(state, db, raw_key, :zset) do
    decoded_key = decode_zset_key(state.decoder, state.decoder_funs, raw_key)
    ZsetStore.del(state.zsets, db, decoded_key)
  end

  defp delete_key(state, db, raw_key) do
    registry_key = {db, raw_key}

    case :ets.lookup(state.key_registry, registry_key) do
      [] ->
        :ok

      [{^registry_key, type}] ->
        delete_from_store(state, db, raw_key, type)
        :ets.delete(state.key_registry, registry_key)
        :ok
    end
  end

  defp parse_score("-inf"), do: :neg_inf
  defp parse_score("+inf"), do: :pos_inf

  defp parse_score(bin) when is_binary(bin) do
    case Float.parse(bin) do
      {score, _} -> score
      :error -> 0.0
    end
  end

  # Decoder wrapper functions that handle optional callbacks

  defp decode_string_key(decoder, decoder_funs, key) do
    if decoder_funs.string_key do
      decoder.decode_string_key(key)
    else
      key
    end
  end

  defp decode_string_value(decoder, decoder_funs, key, value) do
    if decoder_funs.string_value do
      decoder.decode_string_value(key, value)
    else
      value
    end
  end

  defp decode_set_key(decoder, decoder_funs, key) do
    if decoder_funs.set_key do
      decoder.decode_set_key(key)
    else
      key
    end
  end

  defp decode_set_entry(decoder, decoder_funs, key, entry) do
    if decoder_funs.set_entry do
      decoder.decode_set_entry(key, entry)
    else
      entry
    end
  end

  defp decode_list_key(decoder, decoder_funs, key) do
    if decoder_funs.list_key do
      decoder.decode_list_key(key)
    else
      key
    end
  end

  defp decode_list_entry(decoder, decoder_funs, key, entry) do
    if decoder_funs.list_entry do
      decoder.decode_list_entry(key, entry)
    else
      entry
    end
  end

  defp decode_hash_key(decoder, decoder_funs, key) do
    if decoder_funs.hash_key do
      decoder.decode_hash_key(key)
    else
      key
    end
  end

  defp decode_hash_hkey(decoder, decoder_funs, key, hkey) do
    if decoder_funs.hash_hkey do
      decoder.decode_hash_hkey(key, hkey)
    else
      hkey
    end
  end

  defp decode_hash_entry(decoder, decoder_funs, key, hkey, value) do
    if decoder_funs.hash_entry do
      decoder.decode_hash_entry(key, hkey, value)
    else
      value
    end
  end

  defp decode_zset_key(decoder, decoder_funs, key) do
    if decoder_funs.zset_key do
      decoder.decode_zset_key(key)
    else
      key
    end
  end

  defp decode_zset_entry(decoder, decoder_funs, key, entry) do
    if decoder_funs.zset_entry do
      decoder.decode_zset_entry(key, entry)
    else
      entry
    end
  end
end
