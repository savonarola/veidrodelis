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

  @type key :: binary()
  @type value :: binary()
  @type db :: non_neg_integer()

  # Public API

  @doc """
  Starts a Veidrodelis instance that connects to Redis and processes replication stream.

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
    Vdr.MapProj.start_link(opts)
  end

  @doc """
  Stops a Veidrodelis instance.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    Vdr.MapProj.stop(pid)
  end

  @doc """
  Gets the current replication state of a Veidrodelis instance.
  """
  @spec get_replication_state(pid()) :: atom()
  def get_replication_state(pid) when is_pid(pid) do
    Vdr.MapProj.get_replication_state(pid)
  end

  # Redis accessor functions

  @doc """
  Gets the value of a string key.
  """
  @spec get(pid(), db(), key()) :: binary() | nil
  def get(pid, db, key) do
    case Vdr.RedisStream.Replica.call(pid, {:get, db, key}) do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  @doc """
  Returns the length of the list stored at key.
  """
  @spec llen(pid(), db(), key()) :: non_neg_integer()
  def llen(pid, db, key) do
    case Vdr.RedisStream.Replica.call(pid, {:llen, db, key}) do
      {:ok, len} -> len
      {:error, _} -> 0
    end
  end

  @doc """
  Returns the specified elements of the list stored at key.
  """
  @spec lrange(pid(), db(), key(), integer(), integer()) :: [any()]
  def lrange(pid, db, key, start_idx, stop_idx) do
    case Vdr.RedisStream.Replica.call(pid, {:lrange, db, key, start_idx, stop_idx}) do
      {:ok, elements} -> elements
      {:error, _} -> []
    end
  end

  @doc """
  Returns all members of the set stored at key.
  """
  @spec smembers(pid(), db(), key()) :: [any()]
  def smembers(pid, db, key) do
    case Vdr.RedisStream.Replica.call(pid, {:smembers, db, key}) do
      {:ok, members} -> members
      {:error, _} -> []
    end
  end

  @doc """
  Returns the cardinality (number of elements) of the set stored at key.
  """
  @spec scard(pid(), db(), key()) :: non_neg_integer()
  def scard(pid, db, key) do
    case Vdr.RedisStream.Replica.call(pid, {:scard, db, key}) do
      {:ok, count} -> count
      {:error, _} -> 0
    end
  end

  @doc """
  Returns the value associated with field in the hash stored at key.
  """
  @spec hget(pid(), db(), key(), any()) :: any()
  def hget(pid, db, key, field) do
    case Vdr.RedisStream.Replica.call(pid, {:hget, db, key, field}) do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  @doc """
  Returns the values associated with the specified fields in the hash stored at key.
  """
  @spec hmget(pid(), db(), key(), [any()]) :: [any()]
  def hmget(pid, db, key, fields) do
    case Vdr.RedisStream.Replica.call(pid, {:hmget, db, key, fields}) do
      {:ok, values} -> values
      {:error, _} -> []
    end
  end

  @doc """
  Returns all fields and values of the hash stored at key.
  """
  @spec hgetall(pid(), db(), key()) :: [{any(), any()}]
  def hgetall(pid, db, key) do
    case Vdr.RedisStream.Replica.call(pid, {:hgetall, db, key}) do
      {:ok, fields} -> fields
      {:error, _} -> []
    end
  end

  @doc """
  Returns all field names in the hash stored at key.
  """
  @spec hkeys(pid(), db(), key()) :: [any()]
  def hkeys(pid, db, key) do
    case Vdr.RedisStream.Replica.call(pid, {:hkeys, db, key}) do
      {:ok, keys} -> keys
      {:error, _} -> []
    end
  end

  @doc """
  Returns all values in the hash stored at key.
  """
  @spec hvals(pid(), db(), key()) :: [any()]
  def hvals(pid, db, key) do
    case Vdr.RedisStream.Replica.call(pid, {:hvals, db, key}) do
      {:ok, values} -> values
      {:error, _} -> []
    end
  end

  @doc """
  Returns the number of fields in the hash stored at key.
  """
  @spec hlen(pid(), db(), key()) :: non_neg_integer()
  def hlen(pid, db, key) do
    case Vdr.RedisStream.Replica.call(pid, {:hlen, db, key}) do
      {:ok, len} -> len
      {:error, _} -> 0
    end
  end

  @doc """
  Returns the specified range of elements in the sorted set stored at key.
  """
  @spec zrange(pid(), db(), key(), integer(), integer()) :: [{any(), float()}]
  def zrange(pid, db, key, start_idx, stop_idx) do
    case Vdr.RedisStream.Replica.call(pid, {:zrange, db, key, start_idx, stop_idx}) do
      {:ok, members} -> members
      {:error, _} -> []
    end
  end

  @doc """
  Returns the cardinality (number of elements) of the sorted set stored at key.
  """
  @spec zcard(pid(), db(), key()) :: non_neg_integer()
  def zcard(pid, db, key) do
    case Vdr.RedisStream.Replica.call(pid, {:zcard, db, key}) do
      {:ok, count} -> count
      {:error, _} -> 0
    end
  end

  @doc """
  Returns the score of member in the sorted set stored at key.
  """
  @spec zscore(pid(), db(), key(), any()) :: float() | nil
  def zscore(pid, db, key, member) do
    case Vdr.RedisStream.Replica.call(pid, {:zscore, db, key, member}) do
      {:ok, score} -> score
      {:error, _} -> nil
    end
  end
end
