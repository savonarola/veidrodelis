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
        def decode_key(key), do: key

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

      # Access read stores
      string_store = Veidrodelis.strings(:my_instance)
      set_store = Veidrodelis.sets(:my_instance)

      # Query data
      value = Vdr.ETSProj.Read.Strings.get_decoded(string_store, 0, "mykey")
  """

  alias Vdr.ETSProj.Read

  @type id :: term()
  @type key :: binary()
  @type value :: binary()

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
      value = Vdr.ETSProj.Read.Strings.get_decoded(string_store, 0, "mykey")

      # Stop when done
      :ok = Veidrodelis.stop(pid)
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    Vdr.ETSProj.start_link(opts)
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
    Vdr.ETSProj.stop(pid)
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
    Vdr.ETSProj.get_replication_state(pid)
  end

  # Store accessor functions

  @doc """
  Gets the string read store for the given instance ID.

  ## Example

      strings = Veidrodelis.strings(:my_instance)
      value = Vdr.ETSProj.Read.Strings.get_decoded(strings, 0, "mykey")
  """
  @spec strings(id()) :: Read.Strings.t()
  def strings(id) do
    lookup_store(id, :strings)
  end

  @doc """
  Gets the set read store for the given instance ID.

  ## Example

      sets = Veidrodelis.sets(:my_instance)
      members = Vdr.ETSProj.Read.Sets.smembers(sets, 0, "myset")
  """
  @spec sets(id()) :: Read.Sets.t()
  def sets(id) do
    lookup_store(id, :sets)
  end

  @doc """
  Gets the hash read store for the given instance ID.

  ## Example

      hashes = Veidrodelis.hashes(:my_instance)
      all_fields = Vdr.ETSProj.Read.Hashes.hgetall(hashes, 0, "myhash")
  """
  @spec hashes(id()) :: Read.Hashes.t()
  def hashes(id) do
    lookup_store(id, :hashes)
  end

  @doc """
  Gets the sorted set read store for the given instance ID.

  ## Example

      zsets = Veidrodelis.zsets(:my_instance)
      members = Vdr.ETSProj.Read.ZSets.zrange(zsets, 0, "myzset", 0, -1)
  """
  @spec zsets(id()) :: Read.ZSets.t()
  def zsets(id) do
    lookup_store(id, :zsets)
  end

  @doc """
  Gets the list read store for the given instance ID.

  ## Example

      lists = Veidrodelis.lists(:my_instance)
      elements = Vdr.ETSProj.Read.Lists.lrange(lists, 0, "mylist", 0, -1)
  """
  @spec lists(id()) :: Read.Lists.t()
  def lists(id) do
    lookup_store(id, :lists)
  end

  @doc """
  Gets the replica PID for the given instance ID.
  """
  @spec replica_pid(id()) :: pid()
  def replica_pid(id) do
    lookup_store(id, :replica)
  end

  # Private functions

  defp lookup_store(id, type) do
    case :ets.lookup(:veidrodelis_registry, id) do
      [{^id, stores}] ->
        Map.get(stores, type) ||
          raise ArgumentError, "No store registered for #{inspect(id)} / #{inspect(type)}"

      [] ->
        raise ArgumentError, "No store registered for #{inspect(id)}"
    end
  end
end
