defmodule Veidrodelis do
  @moduledoc """
  Veidrodelis - Redis replication stream processor.

  This module provides a simple interface for processing Redis replication streams
  with automatic key type tracking and routing to specialized stores.

  ## Features

    * Type-aware key routing
    * Automatic key type conflict resolution
    * Map-based stores for strings, sets, hashes, sorted sets, and lists
    * Raw binary storage for keys and values

  ## Usage

      # Start a Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(
        host: "localhost",
        port: 6379
      )

      # Query data using accessor functions
      value = Veidrodelis.get(pid, 0, "mykey")
      len = Veidrodelis.llen(pid, 0, "mylist")
      members = Veidrodelis.smembers(pid, 0, "myset")
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
    * `:impl` - Veidrodelis implementation module and options, default: `{Vdr.MapProj, []}`
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
        host: "localhost",
        port: 6379
      ]

      {:ok, pid} = Veidrodelis.start_link(opts)

      # Query data
      value = Veidrodelis.get(pid, 0, "mykey")
      len = Veidrodelis.llen(pid, 0, "mylist")

      # Stop when done
      :ok = Veidrodelis.stop(pid)
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    {impl_module, impl_opts} = Keyword.get(opts, :impl, {Vdr.MapProj, []})
    impl_module.start_link(opts ++ [callback_opts: impl_opts])
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
  @spec get_replication_state(pid() | instance_id()) :: atom()
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

  # Redis accessor functions

  @doc """
  Gets the value of a string key.
  """
  @spec get(instance_id(), db(), key()) :: binary() | nil
  def get(id, db, key) do
    with_handle(id, :get, [db, key])
  end

  @doc """
  Returns the length of the list stored at key.
  """
  @spec llen(instance_id(), db(), key()) :: non_neg_integer()
  def llen(id, db, key) do
    with_handle(id, :llen, [db, key])
  end

  @doc """
  Returns the specified elements of the list stored at key.
  """
  @spec lrange(instance_id(), db(), key(), integer(), integer()) :: [any()]
  def lrange(id, db, key, start_idx, stop_idx) do
    with_handle(id, :lrange, [db, key, start_idx, stop_idx])
  end

  @doc """
  Returns all members of the set stored at key.
  """
  @spec smembers(instance_id(), db(), key()) :: [any()]
  def smembers(id, db, key) do
    with_handle(id, :smembers, [db, key])
  end

  @doc """
  Returns the cardinality (number of elements) of the set stored at key.
  """
  @spec scard(instance_id(), db(), key()) :: non_neg_integer()
  def scard(id, db, key) do
    with_handle(id, :scard, [db, key])
  end

  @doc """
  Returns the value associated with field in the hash stored at key.
  """
  @spec hget(instance_id(), db(), key(), any()) :: any()
  def hget(id, db, key, field) do
    with_handle(id, :hget, [db, key, field])
  end

  @doc """
  Returns the values associated with the specified fields in the hash stored at key.
  """
  @spec hmget(instance_id(), db(), key(), [any()]) :: [any()]
  def hmget(id, db, key, fields) do
    with_handle(id, :hmget, [db, key, fields])
  end

  @doc """
  Returns all fields and values of the hash stored at key.
  """
  @spec hgetall(instance_id(), db(), key()) :: [{any(), any()}]
  def hgetall(id, db, key) do
    with_handle(id, :hgetall, [db, key])
  end

  @doc """
  Returns all field names in the hash stored at key.
  """
  @spec hkeys(instance_id(), db(), key()) :: [any()]
  def hkeys(id, db, key) do
    with_handle(id, :hkeys, [db, key])
  end

  @doc """
  Returns all values in the hash stored at key.
  """
  @spec hvals(instance_id(), db(), key()) :: [any()]
  def hvals(id, db, key) do
    with_handle(id, :hvals, [db, key])
  end

  @doc """
  Returns the number of fields in the hash stored at key.
  """
  @spec hlen(instance_id(), db(), key()) :: non_neg_integer()
  def hlen(id, db, key) do
    with_handle(id, :hlen, [db, key])
  end

  @doc """
  Returns the specified range of elements in the sorted set stored at key.
  """
  @spec zrange(instance_id(), db(), key(), integer(), integer()) :: [{any(), float()}]
  def zrange(id, db, key, start_idx, stop_idx) do
    with_handle(id, :zrange, [db, key, start_idx, stop_idx])
  end

  @doc """
  Returns the cardinality (number of elements) of the sorted set stored at key.
  """
  @spec zcard(instance_id(), db(), key()) :: non_neg_integer()
  def zcard(id, db, key) do
    with_handle(id, :zcard, [db, key])
  end

  @doc """
  Returns the score of member in the sorted set stored at key.
  """
  @spec zscore(instance_id(), db(), key(), any()) :: float() | nil
  def zscore(id, db, key, member) do
    with_handle(id, :zscore, [db, key, member])
  end

  defp with_handle(id, fun_name, fun_args) do
    case Vdr.Registry.lookup(id) do
      {:ok, %Vdr.Handle{handle_state: handle_state, callback_module: callback_module}} ->
        Kernel.apply(callback_module, fun_name, [handle_state | fun_args])

      :not_found ->
        raise "Veidrodelis instance with id #{id} not found"
    end
  end
end
