defmodule Veidrodelis do
  @moduledoc """
  Veidrodelis - Redis replication stream processor with typed stores.

  This module provides a simple interface for processing Redis replication streams
  with automatic key type tracking and routing to specialized stores.

  ## Features

    * Type-aware key routing
    * Automatic key type conflict resolution
    * Pluggable decoder modules for custom data transformations
    * ETS-backed stores for strings, sets, hashes, sorted sets, and lists

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
        host: "localhost",
        port: 6379
      )

      # Access stores
      string_store = Veidrodelis.strings(:my_instance)
      set_store = Veidrodelis.sets(:my_instance)

      # Query data
      value = Vdr.StringStore.get(string_store, 0, "mykey")
  """

  require Logger

  @behaviour Vdr.RedisStream.Callback

  alias Vdr.{StringStore, SetStore, HashStore, ZsetStore, ListStore, CommonStore, Command}

  defstruct [
    :id,
    :decoder,
    :shared_table,
    :strings,
    :sets,
    :hashes,
    :zsets,
    :lists,
    :decode_key
  ]

  @type id :: term()
  @type key :: binary()
  @type value :: binary()

  @type t :: %__MODULE__{
          id: id(),
          decoder: module(),
          shared_table: :ets.tid(),
          strings: StringStore.t(),
          sets: SetStore.t(),
          hashes: HashStore.t(),
          zsets: ZsetStore.t(),
          lists: ListStore.t(),
          decode_key: function()
        }

  # Behaviour callbacks for decoders

  @doc """
  Decodes a key from its binary representation.

  This function decodes keys identically regardless of the Redis data type.
  If a key is "user:123", it will decode to the same value whether it's
  used for a string, set, hash, or sorted set.

  ## Example

      def decode_key(key), do: key  # Identity decoder
      def decode_key(key), do: String.to_atom(key)  # Convert to atom
      def decode_key(<<"prefix:", rest::binary>>), do: rest  # Strip prefix
  """
  @callback decode_key(key()) :: any()

  @doc """
  Decodes a string value given the decoded key.
  """
  @callback decode_string_value(any(), value()) :: term()

  @doc """
  Decodes a set member given the decoded key.
  """
  @callback decode_set_entry(any(), value()) :: term()

  @doc """
  Decodes a hash field key given the decoded hash key.
  """
  @callback decode_hash_hkey(any(), value()) :: any()

  @doc """
  Decodes a hash entry value given the decoded hash key and field key.
  """
  @callback decode_hash_entry(any(), any(), value()) :: term()

  @doc """
  Decodes a sorted set member given the decoded key.
  """
  @callback decode_zset_entry(any(), value()) :: term()

  @doc """
  Decodes a list element given the decoded key.
  """
  @callback decode_list_entry(any(), value()) :: term()

  @optional_callbacks decode_key: 1,
                      decode_string_value: 2,
                      decode_set_entry: 2,
                      decode_hash_hkey: 2,
                      decode_hash_entry: 3,
                      decode_zset_entry: 2,
                      decode_list_entry: 2

  # Public API

  @doc """
  Starts a Veidrodelis instance that connects to Redis and processes replication stream.

  ## Options

    * `:id` - Required. Unique identifier for this Veidrodelis instance
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
      value = StringStore.get_decoded(string_store, 0, "mykey")

      # Stop when done
      :ok = GenServer.stop(pid)
  """
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    decoder = Keyword.fetch!(opts, :decoder)

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

    # Initialize state that will be passed to callbacks
    initial_state = %{id: id, decoder: decoder}

    # Start replica with this module as callback
    replica_opts =
      [
        callback_module: __MODULE__,
        callback_state: initial_state
      ] ++ redis_opts

    Vdr.RedisStream.Replica.start_link(replica_opts)
  end

  @doc """
  Stops a Veidrodelis instance.

  ## Parameters

    * `pid` - The PID of the Replica GenServer returned by start_link

  ## Returns

    * `:ok` - Successfully stopped

  ## Example

      {:ok, pid} = Veidrodelis.start_link(id: :my_instance, decoder: MyDecoder, host: "localhost")
      :ok = Veidrodelis.stop(pid)
  """
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid)
  end

  @doc """
  Gets the current replication state of a Veidrodelis instance.

  ## Parameters

    * `pid` - The PID of the Replica GenServer returned by start_link

  ## Returns

    * `:connecting` - Connecting to Redis
    * `:handshake` - Performing replication handshake
    * `:rdb` - Receiving RDB snapshot
    * `:streaming` - Actively streaming commands

  ## Example

      {:ok, pid} = Veidrodelis.start_link(id: :my_instance, decoder: MyDecoder, host: "localhost")
      state = Veidrodelis.get_replication_state(pid)
      #=> :streaming
  """
  @spec get_replication_state(pid()) :: atom()
  def get_replication_state(pid) when is_pid(pid) do
    Vdr.RedisStream.Replica.get_replication_state(pid)
  end

  # RedisStream.Callback implementation

  @impl Vdr.RedisStream.Callback
  def on_replication_start(%__MODULE__{} = state) do
    # Reinitialize with existing ID and decoder
    reinitialize_state(state)
  end

  def on_replication_start(init_opts) do
    # Initialize new state with decoder
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
    # Destroy stores
    try do
      destroy_stores(state)
    rescue
      ArgumentError -> :ok
    end

    # Unregister from Vdr.Registry (this will call the cleanup function)
    Vdr.Registry.unregister(state.id)

    :ok
  end

  # Handle destroy when state hasn't been initialized yet
  def on_destroy(_state) do
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

  @doc """
  Gets the list store for the given instance ID.
  """
  @spec lists(id()) :: ListStore.t()
  def lists(id) do
    lookup_store(id, :lists)
  end

  # Private functions

  defp initialize_state(%{id: id, decoder: decoder}) do
    # Register with Vdr.Registry for automatic cleanup
    cleanup_fun = fn ->
      # Deregister from global ETS registry
      :ets.delete(:veidrodelis_registry, {id, :strings})
      :ets.delete(:veidrodelis_registry, {id, :sets})
      :ets.delete(:veidrodelis_registry, {id, :hashes})
      :ets.delete(:veidrodelis_registry, {id, :zsets})
      :ets.delete(:veidrodelis_registry, {id, :lists})
      :ets.delete(:veidrodelis_registry, {id, :replica})
    end

    case Vdr.Registry.register(id, self(), cleanup_fun) do
      :ok ->
        # Create shared ETS table for all stores (protected so other processes can read)
        # Using ordered_set for efficient sorted operations (especially for zsets)
        shared_table = :ets.new(:vdr_store, [:ordered_set, :protected])

        # Get decoder function for keys
        decode_key_fun = get_decode_key_fun(decoder)

        # Create stores with shared table and decoder functions
        strings = StringStore.new(shared_table, decode_string_value_fun(decoder))
        sets = SetStore.new(shared_table, decode_set_entry_fun(decoder))

        hashes =
          HashStore.new(
            shared_table,
            decode_hash_hkey_fun(decoder),
            decode_hash_entry_fun(decoder)
          )

        zsets = ZsetStore.new(shared_table, decode_zset_entry_fun(decoder))
        lists = ListStore.new(shared_table, decode_list_entry_fun(decoder))

        # Register stores in global registry
        :ets.insert(:veidrodelis_registry, {{id, :strings}, strings})
        :ets.insert(:veidrodelis_registry, {{id, :sets}, sets})
        :ets.insert(:veidrodelis_registry, {{id, :hashes}, hashes})
        :ets.insert(:veidrodelis_registry, {{id, :zsets}, zsets})
        :ets.insert(:veidrodelis_registry, {{id, :lists}, lists})
        :ets.insert(:veidrodelis_registry, {{id, :replica}, self()})

        state = %__MODULE__{
          id: id,
          decoder: decoder,
          shared_table: shared_table,
          strings: strings,
          sets: sets,
          hashes: hashes,
          zsets: zsets,
          lists: lists,
          decode_key: decode_key_fun
        }

        {:ok, state}

      {:error, reason} ->
        {:error, {:registry_register_failed, reason}}
    end
  end

  defp reinitialize_state(%__MODULE__{id: id, decoder: decoder} = state) do
    # Destroy old stores
    destroy_stores(state)

    # Unregister from Vdr.Registry (this will call the cleanup function)
    Vdr.Registry.unregister(id)

    # Create new state (which will register again)
    initialize_state(%{id: id, decoder: decoder})
  end

  defp destroy_stores(%__MODULE__{} = state) do
    # Delete shared table (used by StringStore, HashStore, SetStore, ZsetStore)
    :ets.delete(state.shared_table)
    :ok
  end

  defp lookup_store(id, type) do
    case :ets.lookup(:veidrodelis_registry, {id, type}) do
      [{{^id, ^type}, store}] -> store
      [] -> raise ArgumentError, "No store registered for #{inspect(id)} / #{inspect(type)}"
    end
  end

  defp handle_command(state, db, %Command.Set{key: raw_key, value: raw_value}) do
    decoded_key = state.decode_key.(raw_key)
    StringStore.set(state.strings, db, decoded_key, raw_value)
  end

  defp handle_command(state, db, %Command.MSet{pairs: pairs}) do
    decoded_pairs =
      Enum.map(pairs, fn {raw_key, raw_value} ->
        {state.decode_key.(raw_key), raw_value}
      end)

    StringStore.mset(state.strings, db, decoded_pairs)
  end

  defp handle_command(state, db, %Command.Append{key: raw_key, value: raw_value}) do
    decoded_key = state.decode_key.(raw_key)
    StringStore.append(state.strings, db, decoded_key, raw_value)
  end

  defp handle_command(state, db, %Command.SetRange{key: raw_key, offset: offset, value: raw_value}) do
    decoded_key = state.decode_key.(raw_key)
    StringStore.setrange(state.strings, db, decoded_key, offset, raw_value)
  end

  defp handle_command(state, db, %Command.SetBit{key: raw_key, offset: offset, value: bit}) do
    decoded_key = state.decode_key.(raw_key)
    StringStore.setbit(state.strings, db, decoded_key, offset, bit)
  end

  # List commands
  defp handle_command(state, db, %Command.RPush{key: raw_key, values: values}) do
    decoded_key = state.decode_key.(raw_key)
    ListStore.rpush(state.lists, db, decoded_key, values)
  end

  defp handle_command(state, db, %Command.LPush{key: raw_key, values: values}) do
    decoded_key = state.decode_key.(raw_key)
    ListStore.lpush(state.lists, db, decoded_key, values)
  end

  defp handle_command(state, db, %Command.RPushX{key: raw_key, values: values}) do
    decoded_key = state.decode_key.(raw_key)
    ListStore.rpushx(state.lists, db, decoded_key, values)
  end

  defp handle_command(state, db, %Command.LPushX{key: raw_key, values: values}) do
    decoded_key = state.decode_key.(raw_key)
    ListStore.lpushx(state.lists, db, decoded_key, values)
  end

  defp handle_command(state, db, %Command.LPop{key: raw_key}) do
    decoded_key = state.decode_key.(raw_key)
    ListStore.lpop(state.lists, db, decoded_key)
  end

  defp handle_command(state, db, %Command.RPop{key: raw_key}) do
    decoded_key = state.decode_key.(raw_key)
    ListStore.rpop(state.lists, db, decoded_key)
  end

  defp handle_command(state, db, %Command.LRem{key: raw_key, count: count, value: value}) do
    decoded_key = state.decode_key.(raw_key)
    ListStore.lrem(state.lists, db, decoded_key, count, value)
  end

  defp handle_command(state, db, %Command.LTrim{key: raw_key, start: start_idx, stop: stop_idx}) do
    decoded_key = state.decode_key.(raw_key)
    ListStore.ltrim(state.lists, db, decoded_key, start_idx, stop_idx)
  end

  defp handle_command(state, db, %Command.LSet{key: raw_key, index: index, value: value}) do
    decoded_key = state.decode_key.(raw_key)
    ListStore.lset(state.lists, db, decoded_key, index, value)
  end

  defp handle_command(
        state,
        db,
        %Command.LInsert{key: raw_key, before_after: position, pivot: pivot, element: element}
      ) do
    decoded_key = state.decode_key.(raw_key)
    ListStore.linsert(state.lists, db, decoded_key, position, pivot, element)
  end

  defp handle_command(state, db, %Command.RPopLPush{source: raw_source, destination: raw_dest}) do
    decoded_source = state.decode_key.(raw_source)
    decoded_dest = state.decode_key.(raw_dest)
    ListStore.rpoplpush(state.lists, db, decoded_source, decoded_dest)
  end

  defp handle_command(state, db, %Command.SAdd{key: raw_key, members: members}) do
    decoded_key = state.decode_key.(raw_key)
    SetStore.sadd(state.sets, db, decoded_key, members)
  end

  defp handle_command(state, db, %Command.SRem{key: raw_key, members: members}) do
    decoded_key = state.decode_key.(raw_key)
    SetStore.srem(state.sets, db, decoded_key, members)
  end

  defp handle_command(state, db, %Command.SMove{
         source: raw_source,
         destination: raw_dest,
         member: member
       }) do
    decoded_source = state.decode_key.(raw_source)
    decoded_dest = state.decode_key.(raw_dest)
    SetStore.smove(state.sets, db, decoded_source, decoded_dest, member)
  end

  defp handle_command(state, db, %Command.SInterStore{destination: raw_dest, keys: raw_keys}) do
    decoded_dest = state.decode_key.(raw_dest)
    decoded_keys = Enum.map(raw_keys, &state.decode_key.(&1))
    SetStore.sinterstore(state.sets, db, decoded_dest, decoded_keys)
  end

  defp handle_command(state, db, %Command.SUnionStore{destination: raw_dest, keys: raw_keys}) do
    decoded_dest = state.decode_key.(raw_dest)
    decoded_keys = Enum.map(raw_keys, &state.decode_key.(&1))
    SetStore.sunionstore(state.sets, db, decoded_dest, decoded_keys)
  end

  defp handle_command(state, db, %Command.SDiffStore{destination: raw_dest, keys: raw_keys}) do
    decoded_dest = state.decode_key.(raw_dest)
    decoded_keys = Enum.map(raw_keys, &state.decode_key.(&1))
    SetStore.sdiffstore(state.sets, db, decoded_dest, decoded_keys)
  end

  defp handle_command(state, db, %Command.HSet{key: raw_key, fields: field_values}) do
    decoded_key = state.decode_key.(raw_key)
    HashStore.hset(state.hashes, db, decoded_key, field_values)
  end

  defp handle_command(state, db, %Command.HDel{key: raw_key, fields: fields}) do
    decoded_key = state.decode_key.(raw_key)
    HashStore.hdel(state.hashes, db, decoded_key, fields)
  end

  defp handle_command(state, db, %Command.ZAdd{key: raw_key, members: members}) do
    decoded_key = state.decode_key.(raw_key)
    ZsetStore.zadd(state.zsets, db, decoded_key, members)
  end

  defp handle_command(state, db, %Command.ZRem{key: raw_key, members: members}) do
    decoded_key = state.decode_key.(raw_key)
    ZsetStore.zrem(state.zsets, db, decoded_key, members)
  end

  defp handle_command(state, db, %Command.ZPopMax{key: raw_key, count: count}) do
    decoded_key = state.decode_key.(raw_key)
    ZsetStore.zpopmax(state.zsets, db, decoded_key, count)
    :ok
  end

  defp handle_command(state, db, %Command.ZPopMin{key: raw_key, count: count}) do
    decoded_key = state.decode_key.(raw_key)
    ZsetStore.zpopmin(state.zsets, db, decoded_key, count)
    :ok
  end

  defp handle_command(state, db, %Command.ZRemRangeByRank{
         key: raw_key,
         start: start_idx,
         stop: stop_idx
       }) do
    decoded_key = state.decode_key.(raw_key)
    ZsetStore.zremrangebyrank(state.zsets, db, decoded_key, start_idx, stop_idx)
  end

  defp handle_command(state, db, %Command.ZRemRangeByScore{key: raw_key, min: min, max: max}) do
    decoded_key = state.decode_key.(raw_key)
    # Parse min/max from binary strings
    min_score = parse_score(min)
    max_score = parse_score(max)
    ZsetStore.zremrangebyscore(state.zsets, db, decoded_key, min_score, max_score)
  end

  defp handle_command(state, db, %Command.ZRemRangeByLex{key: raw_key, min: min, max: max}) do
    decoded_key = state.decode_key.(raw_key)
    ZsetStore.zremrangebylex(state.zsets, db, decoded_key, min, max)
  end

  defp handle_command(state, db, %Command.ZUnionStore{
         destination: raw_dest,
         keys: raw_keys,
         weights: weights,
         aggregate: aggregate
       }) do
    decoded_dest = state.decode_key.(raw_dest)
    decoded_keys = Enum.map(raw_keys, &state.decode_key.(&1))

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
    decoded_dest = state.decode_key.(raw_dest)
    decoded_keys = Enum.map(raw_keys, &state.decode_key.(&1))

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


  defp delete_key(state, db, raw_key) do
    decoded_key = state.decode_key.(raw_key)
    CommonStore.del(state.shared_table, db, decoded_key)
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

  defp get_decode_key_fun(decoder) do
    if function_exported?(decoder, :decode_key, 1) do
      &decoder.decode_key/1
    else
      &identity/1
    end
  end

  defp decode_string_value_fun(decoder) do
    if function_exported?(decoder, :decode_string_value, 2) do
      &decoder.decode_string_value/2
    else
      &identity2/2
    end
  end

  defp decode_set_entry_fun(decoder) do
    if function_exported?(decoder, :decode_set_entry, 2) do
      &decoder.decode_set_entry/2
    else
      &identity2/2
    end
  end

  defp decode_hash_hkey_fun(decoder) do
    if function_exported?(decoder, :decode_hash_hkey, 2) do
      &decoder.decode_hash_hkey/2
    else
      &identity2/2
    end
  end

  defp decode_hash_entry_fun(decoder) do
    if function_exported?(decoder, :decode_hash_entry, 3) do
      &decoder.decode_hash_entry/3
    else
      &identity3/3
    end
  end

  defp decode_zset_entry_fun(decoder) do
    if function_exported?(decoder, :decode_zset_entry, 2) do
      &decoder.decode_zset_entry/2
    else
      &identity2/2
    end
  end

  defp decode_list_entry_fun(decoder) do
    if function_exported?(decoder, :decode_list_entry, 2) do
      &decoder.decode_list_entry/2
    else
      &identity2/2
    end
  end

  defp identity(a), do: a

  defp identity2(_a, b), do: b

  defp identity3(_a, _b, c), do: c
end
