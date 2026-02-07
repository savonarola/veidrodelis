defmodule Veidrodelis do
  @moduledoc """
  This is the main module for managing in-process replicas of Redis/Valkey data.

  This module provides a simple interface for starting/stopping/inspecting replica instances,
  as well as commands for accessing the replicated data.

  Veidrodelis instance is a single GenServer process that connects to Redis/Valkey, fetches
  the data via replication protocol and builds an in-memory projection of the data.

  The process is registered under global id which is used for reading the replicated
  data without calls to the replicating GenServer.

  ## Sample Usage

  ```elixir
    # Start a Veidrodelis instance
    {:ok, pid} = Veidrodelis.start_link(
      id: :my_instance,
      host: "localhost",
      port: 6379
    )

    # Query data using accessor functions
    {:ok, value} = Veidrodelis.get(:my_instance, 0, "mykey")
    {:ok, len} = Veidrodelis.llen(:my_instance, 0, "mylist")

    # Read ransacitons
    {:ok, [{:ok, debit}, {:ok, credit}]} = Veidrodelis.read_tx(:my_instance, 0, [
      {:get, "account:123:debit"},
      {:get, "account:123:credit"}
    ])

    # Read transactions via Lua script
    {:ok, [debit, credit]} = Veidrodelis.read_tx(
      :my_instance,
      0,
      "return {ts.get('account:123:debit'), ts.get('account:123:credit')}"
    )

    # Stop the instance
    :ok = Veidrodelis.stop(pid)
  ```
  """

  alias Vdr.RedisStream.Replica

  @type instance_id :: term()
  @type key :: binary()
  @type value :: binary()
  @type db :: non_neg_integer()

  # Public API

  @doc """
  Starts a Veidrodelis instance that connects to Redis and processes replication stream.

  ## Options

    * `:id` - Veidrodelis instance ID, required
    * `:host` - Redis host (default: "localhost"). Cannot be used with `:sentinel`.
    * `:port` - Redis port (default: 6379). Cannot be used with `:sentinel`.
    * `:sentinel` - Sentinel configuration (keyword list). Cannot be used with `:host`/`:port`.
      * `:sentinels` - List of sentinel nodes (required), each with `:host` and `:port`
      * `:group` - Name of the primary group in sentinel (required)
      * `:role` - Server role to discover: `:primary` or `:replica` (default: `:primary`)
      * `:connect_opts` - Redix connection options for sentinel connections (optional)
      * `:replica_connect_opts` - Redix connection options for discovered Redis server (optional)
    * `:username` - Redis username for ACL authentication (default: nil). Only for direct connections.
    * `:password` - Redis password (default: nil). Only for direct connections.
    * `:ssl` - Use SSL/TLS (default: false). Only for direct connections.
    * `:ssl_opts` - SSL options (default: []). Only for direct connections.
    * `:reconnect` - Enable automatic reconnection (default: true)
    * `:reconnect_delay_ms` - Initial delay before reconnection in ms (default: 1000)
    * `:max_reconnect_delay_ms` - Maximum delay between reconnection attempts in ms (default: 30000)

  For full documentation of sentinel options and advanced features, see `Vdr.RedisStream.Replica`.

  ## Returns

    * `{:ok, pid}` - Successfully started (returns Replica GenServer PID)
    * `{:error, reason}` - Failed to start

  ## Examples

  ### Direct Connection

  ```elixir
  opts = [
    id: :my_instance,
    host: "localhost",
    port: 6379
  ]
  {:ok, pid} = Veidrodelis.start_link(opts)
  ```

  ### Sentinel Connection

  ```elixir
  opts = [
    id: :my_instance,
    sentinel: [
      sentinels: [
        [host: "sentinel1", port: 26379],
        [host: "sentinel2", port: 26379]
      ],
      group: "myprimary",
      role: :primary,
      # Optional: Connection options for sentinel
      connect_opts: [timeout: 1000],
      # Optional: Connection options for Redis server
      replica_connect_opts: [password: "redis_password", ssl: true]
    ]
  ]
  {:ok, pid} = Veidrodelis.start_link(opts)
  ```
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    Vdr.TSProj.start_link(opts)
  end

  @doc """
  Stops a Veidrodelis instance.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    Replica.stop(pid)
  end

  @doc """
  Gets the current replication state of a Veidrodelis instance.
  """
  @spec get_replication_state(pid() | instance_id()) :: Replica.replica_state()
  def get_replication_state(pid) when is_pid(pid) do
    Replica.get_replication_state(pid)
  end

  def get_replication_state(id) do
    case Vdr.Registry.lookup(id) do
      {:ok, %Vdr.Handle{pid: pid}} ->
        Replica.get_replication_state(pid)

      :not_found ->
        raise "Veidrodelis instance with id #{id} not found"
    end
  end

  @doc """
  Gets the host and port of the currently connected Redis server.

  Returns the actual host and port that the Veidrodelis instance is connected to.
  For sentinel-based connections, this returns the discovered server address.
  For direct connections, this returns the configured host and port.

  ## Parameters

    * `pid_or_id` - Either the Replica GenServer PID or the Veidrodelis instance ID

  ## Returns

    * `{:ok, {host, port}}` - The connected host (string) and port (integer)
    * `{:error, :not_connected}` - Replica is not currently connected

  ## Examples

  ```elixir
  # Using instance ID
  {:ok, {host, port}} = Veidrodelis.get_connected_to(:my_instance)

  # Using PID directly
  {:ok, pid} = Veidrodelis.start_link(id: :test, host: "localhost", port: 6379)
  {:ok, {host, port}} = Veidrodelis.get_connected_to(pid)
  ```
  """
  @spec get_connected_to(pid() | instance_id()) ::
          {:ok, {String.t(), non_neg_integer()}} | {:error, :not_connected}
  def get_connected_to(pid) when is_pid(pid) do
    Replica.connected_to(pid)
  end

  def get_connected_to(id) do
    case Vdr.Registry.lookup(id) do
      {:ok, %Vdr.Handle{pid: pid}} ->
        Replica.connected_to(pid)

      :not_found ->
        raise "Veidrodelis instance with id #{id} not found"
    end
  end

  @doc """
  Subscribes to updates for a specific key in a database.

  When the key is modified, the calling process will receive a message:
  `{ref, %Vdr.WatchEvent.Update{command: cmd, db: db}}`

  When the replica transitions to streaming mode after an RDB transfer, the calling
  process will receive: `{ref, %Vdr.WatchEvent.Init{}}`

  ## Parameters

    * `id` - Veidrodelis instance ID
    * `db` - Database number
    * `key` - The key to watch (binary)
    * `ref` - Reference value to identify this watch in notifications

  ## Returns

    * `:ok` - Successfully subscribed
    * `{:error, :not_found}` - Instance not found
    * `{:error, :already_registered}` - This process is already watching this key

  ## Example

  ```elixir
  # Subscribe to key updates
  :ok = Veidrodelis.watch(:my_instance, 0, "user:123", :my_watch_ref)

  # Receive notifications
  receive do
    {:my_watch_ref, %Vdr.WatchEvent.Update{command: cmd, db: db}} ->
      IO.inspect({:update, cmd, db})

    {:my_watch_ref, %Vdr.WatchEvent.Init{}} ->
      IO.puts("Streaming mode started")
  end
  ```
  """
  @spec watch(instance_id(), db(), key(), term()) :: :ok | {:error, term()}
  def watch(id, db, key, ref) when is_integer(db) and is_binary(key) do
    case Vdr.Registry.lookup(id) do
      {:ok, %Vdr.Handle{pid: pid}} ->
        case GenServer.call(pid, {:callback_call, {:watch, self(), db, key, ref}}) do
          {:ok, :ok} -> :ok
          {:ok, {:error, reason}} -> {:error, reason}
          {:error, reason} -> {:error, reason}
        end

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  Unsubscribes from updates for a specific key.

  ## Parameters

    * `id` - Veidrodelis instance ID
    * `db` - Database number
    * `key` - The key to unwatch (binary)

  ## Returns

    * `:ok` - Successfully unsubscribed
    * `{:error, :not_found}` - Instance or watch not found

  ## Example

  ```elixir
  # Unsubscribe from key updates
  :ok = Veidrodelis.unwatch(:my_instance, 0, "user:123")
  ```
  """
  @spec unwatch(instance_id(), db(), key()) :: :ok | {:error, term()}
  def unwatch(id, db, key) when is_integer(db) and is_binary(key) do
    case Vdr.Registry.lookup(id) do
      {:ok, %Vdr.Handle{pid: pid}} ->
        case GenServer.call(pid, {:callback_call, {:unwatch, self(), db, key}}) do
          {:ok, :ok} -> :ok
          {:ok, {:error, reason}} -> {:error, reason}
          {:error, reason} -> {:error, reason}
        end

      :not_found ->
        {:error, :not_found}
    end
  end

  # Data access methods

  @doc """
  Gets the value of a string key.
  """
  @spec get(instance_id(), db(), key()) :: binary() | nil | {:error, term()}
  def get(id, db, key) do
    with_single_command_read_tx(id, db, {:get, key})
  end

  @doc """
  Returns the length of the list stored at key.
  """
  @spec llen(instance_id(), db(), key()) :: non_neg_integer() | {:error, term()}
  def llen(id, db, key) do
    with_single_command_read_tx(id, db, {:llen, key})
  end

  @doc """
  Returns the specified elements of the list stored at key.
  """
  @spec lrange(instance_id(), db(), key(), integer(), integer()) :: [any()] | {:error, term()}
  def lrange(id, db, key, start_idx, stop_idx) do
    with_single_command_read_tx(id, db, {:lrange, key, start_idx, stop_idx})
  end

  @doc """
  Returns all members of the set stored at key.
  """
  @spec smembers(instance_id(), db(), key()) :: [any()] | {:error, term()}
  def smembers(id, db, key) do
    with_single_command_read_tx(id, db, {:smembers, key})
  end

  @doc """
  Returns the cardinality (number of elements) of the set stored at key.
  """
  @spec scard(instance_id(), db(), key()) :: non_neg_integer() | {:error, term()}
  def scard(id, db, key) do
    with_single_command_read_tx(id, db, {:scard, key})
  end

  @doc """
  Returns whether member is a member of the set stored at key.
  """
  @spec sismember(instance_id(), db(), key(), any()) :: boolean() | {:error, term()}
  def sismember(id, db, key, member) do
    with_single_command_read_tx(id, db, {:sismember, key, member})
  end

  @doc """
  Gets the first (lexicographically minimum) member from a set.

  Returns the member or nil if the set is empty/doesn't exist.

  ## Examples

  ```elixir
  {:ok, pid} = Veidrodelis.start_link(id: :my_instance)
  {:ok, first} = Veidrodelis.sfirst(:my_instance, 0, "myset")
  # Returns: "a" (assuming set contains ["a", "b", "c"])
  ```
  """
  @spec sfirst(instance_id(), db(), key()) :: binary() | nil | {:error, term()}
  def sfirst(id, db, key) do
    with_single_command_read_tx(id, db, {:sfirst, key})
  end

  @doc """
  Gets the last (lexicographically maximum) member from a set.

  Returns the member or nil if the set is empty/doesn't exist.

  ## Examples

  ```elixir
    {:ok, pid} = Veidrodelis.start_link(id: :my_instance)
    {:ok, last} = Veidrodelis.slast(:my_instance, 0, "myset")
    # Returns: "c" (assuming set contains ["a", "b", "c"])
  ```
  """
  @spec slast(instance_id(), db(), key()) :: binary() | nil | {:error, term()}
  def slast(id, db, key) do
    with_single_command_read_tx(id, db, {:slast, key})
  end

  @doc """
  Gets the next member after the given member in a set.

  Returns the next member or nil if no next element exists.

  ## Examples

  ```elixir
  {:ok, pid} = Veidrodelis.start_link(id: :my_instance)
  {:ok, next} = Veidrodelis.snext(:my_instance, 0, "myset", "a")
  # Returns: "b" (assuming set contains ["a", "b", "c"])
  ```
  """
  @spec snext(instance_id(), db(), key(), any()) :: binary() | nil | {:error, term()}
  def snext(id, db, key, member) do
    with_single_command_read_tx(id, db, {:snext, key, member})
  end

  @doc """
  Gets the previous member before the given member in a set.

  Returns the previous member or nil if no previous element exists.

  ## Examples

  ```elixir
  {:ok, pid} = Veidrodelis.start_link(id: :my_instance)
  {:ok, prev} = Veidrodelis.sprev(:my_instance, 0, "myset", "c")
  # Returns: "b" (assuming set contains ["a", "b", "c"])
  ```
  """
  @spec sprev(instance_id(), db(), key(), any()) :: binary() | nil | {:error, term()}
  def sprev(id, db, key, member) do
    with_single_command_read_tx(id, db, {:sprev, key, member})
  end

  @doc """
  Returns the value associated with field in the hash stored at key.
  """
  @spec hget(instance_id(), db(), key(), any()) :: any() | {:error, term()}
  def hget(id, db, key, field) do
    with_single_command_read_tx(id, db, {:hget, key, field})
  end

  @doc """
  Returns the values associated with the specified fields in the hash stored at key.
  """
  @spec hmget(instance_id(), db(), key(), [any()]) :: [any()] | {:error, term()}
  def hmget(id, db, key, fields) do
    with_single_command_read_tx(id, db, {:hmget, key, fields})
  end

  @doc """
  Returns all fields and values of the hash stored at key.
  """
  @spec hgetall(instance_id(), db(), key()) :: [{any(), any()}] | {:error, term()}
  def hgetall(id, db, key) do
    with_single_command_read_tx(id, db, {:hgetall, key})
  end

  @doc """
  Returns all field names in the hash stored at key.
  """
  @spec hkeys(instance_id(), db(), key()) :: [any()] | {:error, term()}
  def hkeys(id, db, key) do
    with_single_command_read_tx(id, db, {:hkeys, key})
  end

  @doc """
  Returns all values in the hash stored at key.
  """
  @spec hvals(instance_id(), db(), key()) :: [any()] | {:error, term()}
  def hvals(id, db, key) do
    with_single_command_read_tx(id, db, {:hvals, key})
  end

  @doc """
  Returns the number of fields in the hash stored at key.
  """
  @spec hlen(instance_id(), db(), key()) :: non_neg_integer() | {:error, term()}
  def hlen(id, db, key) do
    with_single_command_read_tx(id, db, {:hlen, key})
  end

  @doc """
  Returns the specified range of elements in the sorted set stored at key.

  If `with_scores` is `true`, returns a list of `{member, score}` tuples.
  If `with_scores` is `false`, returns a list of members only.
  """
  @spec zrange(instance_id(), db(), key(), integer(), integer(), boolean()) ::
          [{any(), float()}] | [any()] | {:error, term()}
  def zrange(id, db, key, start_idx, stop_idx, with_scores \\ true) do
    with_single_command_read_tx(id, db, {:zrange, key, start_idx, stop_idx, with_scores})
  end

  @doc """
  Returns the cardinality (number of elements) of the sorted set stored at key.
  """
  @spec zcard(instance_id(), db(), key()) :: non_neg_integer() | {:error, term()}
  def zcard(id, db, key) do
    with_single_command_read_tx(id, db, {:zcard, key})
  end

  @doc """
  Returns the score of member in the sorted set stored at key.
  """
  @spec zscore(instance_id(), db(), key(), any()) :: float() | nil | {:error, term()}
  def zscore(id, db, key, member) do
    with_single_command_read_tx(id, db, {:zscore, key, member})
  end

  @doc """
  Returns all members in the sorted set stored at key with scores between min and max (inclusive).

  If `with_scores` is `true`, returns a list of `{member, score}` tuples.
  If `with_scores` is `false`, returns a list of members only.

  ## Examples

  ```elixir
  {:ok, pid} = Veidrodelis.start_link(id: :my_instance)
  {:ok, members} = Veidrodelis.zrangebyscore(:my_instance, 0, "myzset", 1.0, 3.0, true)
  # Returns: [{"one", 1.0}, {"two", 2.0}, {"three", 3.0}]

  {:ok, members} = Veidrodelis.zrangebyscore(:my_instance, 0, "myzset", 1.0, 3.0, false)
  # Returns: ["one", "two", "three"]
  ```
  """
  @spec zrangebyscore(instance_id(), db(), key(), float(), float(), boolean()) ::
          [{any(), float()}] | [any()] | {:error, term()}
  def zrangebyscore(id, db, key, min, max, with_scores \\ true) do
    with_single_command_read_tx(id, db, {:zrangebyscore, key, min, max, with_scores})
  end

  @doc """
  Returns the rank (0-based index) where the member would be in the sorted set,
  ordered from lowest to highest score. Returns `nil` if the member or key doesn't exist.
  """
  @spec zrank(instance_id(), db(), key(), any()) :: non_neg_integer() | nil | {:error, term()}
  def zrank(id, db, key, member) do
    with_single_command_read_tx(id, db, {:zrank, key, member})
  end

  @doc """
  Returns the rank (0-based index) where the member would be in the sorted set,
  ordered from highest to lowest score. Returns `nil` if the member or key doesn't exist.
  """
  @spec zrevrank(instance_id(), db(), key(), any()) :: non_neg_integer() | nil | {:error, term()}
  def zrevrank(id, db, key, member) do
    with_single_command_read_tx(id, db, {:zrevrank, key, member})
  end

  @doc """
  Executes multiple read-only commands or a Lua script atomically.

  ## With a list of commands

  Executes multiple read commands atomically.
  Commands are executed in order and their results are returned as a list of tuples.

  ### Supported Commands

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

  ### Example
  ```elixir
    {:ok, [value1, value2]} = Veidrodelis.read_tx(:my_instance, 0, [
      {:get, "key1"},
      {:hget, "hash1", "field1"}
    ])
  ```

  ## With a Lua script

  Executes a Lua script atomically under the storage mutex. The script has access to:
  - `ts.get(key)` - Get a string value
  - `ts.hget(key, field)` - Get a hash field value
  - `ts.llen(key)` - Get list length
  - `ts.lrange(key, start, stop)` - Get list range
  - `ts.smembers(key)` - Get set members
  - `ts.sismember(key, member)` - Check set membership
  - `ts.scard(key)` - Get set cardinality
  - `ts.hgetall(key)` - Get all hash fields and values
  - `ts.hkeys(key)` - Get hash field names
  - `ts.hvals(key)` - Get hash values
  - `ts.hlen(key)` - Get hash length
  - `ts.hexists(key, field)` - Check if hash field exists
  - `ts.zscore(key, member)` - Get sorted set member score
  - `ts.zcard(key)` - Get sorted set cardinality
  - `ts.zrange(key, start, stop)` - Get sorted set range
  - `ts.zrangebyscore(key, min, max)` - Get sorted set range by score
  - `ts.zrank(key, member)` - Get sorted set member rank
  - `ts.zrevrank(key, member)` - Get sorted set member reverse rank
  - `ts.zcount(key, min, max)` - Count sorted set members in score range
  - `ts.zfirst(key)` - Get first sorted set member (returns score, member)
  - `ts.zlast(key)` - Get last sorted set member (returns score, member)
  - `ts.znext(key, score, member)` - Get next sorted set member (returns score, member)
  - `ts.zprev(key, score, member)` - Get previous sorted set member (returns score, member)

  ### Example

      {:ok, pid} = Veidrodelis.start_link(id: :my_instance)
      script = "return ts.get('key1')"
      {:ok, result} = Veidrodelis.read_tx(:my_instance, 0, script)

  ## Returns

    * `{:ok, results}` - For commands: list of results. For scripts: the script's return value
    * `{:error, :not_ready}` - Instance not ready
    * `{:error, :readonly_violation}` - Write command detected (commands only)
    * `{:error, reason}` - Script execution error (scripts only)
  """
  @spec read_tx(instance_id(), db(), [tuple()] | binary()) ::
          {:ok, [term()] | term()} | {:error, term()}
  def read_tx(id, db, commands) when is_list(commands) do
    with_handle(id, :read_tx, [db, commands])
  end

  def read_tx(id, db, script) when is_binary(script) do
    with_handle(id, :tx, [db, script])
  end

  @doc """
  Compiles a Lua script to bytecode for faster execution.

  The compiled bytecode can be passed to `read_tx/3` instead of a script string.
  This is useful when the same script will be executed multiple times.

  ## Examples

      {:ok, pid} = Veidrodelis.start_link(id: :my_instance)
      script = "return ts.get('key1')"
      {:ok, bytecode} = Veidrodelis.lua_load(:my_instance, script)
      {:ok, result} = Veidrodelis.read_tx(:my_instance, 0, bytecode)
  """
  @spec lua_load(instance_id(), binary()) :: {:ok, binary()} | {:error, term()}
  def lua_load(id, script) when is_binary(script) do
    with_handle(id, :lua_load, [script])
  end

  defp with_handle(id, fun_name, fun_args, check_ready \\ false) do
    case Vdr.Registry.lookup(id) do
      {:ok, %Vdr.Handle{handle_state: handle_state, callback_module: callback_module}} ->
        if check_ready and not handle_state.ready do
          {:error, :not_ready}
        else
          Kernel.apply(callback_module, fun_name, [handle_state | fun_args])
        end

      :not_found ->
        {:error, :not_connected}
    end
  end

  # Helper for single read command - checks ready flag and calls Vdr.TS.read_tx directly
  defp with_single_command_read_tx(id, db, command) do
    case Vdr.Registry.lookup(id) do
      {:ok, %Vdr.Handle{handle_state: %{ready: ready, ts_storage: ts_storage}}} ->
        if ready do
          case Vdr.TS.read_tx(ts_storage, db, [command]) do
            {:ok, [{:ok, _} = result]} -> result
            {:ok, [{:error, _} = error]} -> error
            {:error, _} = error -> error
          end
        else
          {:error, :not_ready}
        end

      :not_found ->
        {:error, :not_connected}
    end
  end
end
