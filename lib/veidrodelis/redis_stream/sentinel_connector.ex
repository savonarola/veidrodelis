defmodule Vdr.RedisStream.SentinelConnector do
  @moduledoc false
  # Internal module for Redis Sentinel discovery and connection.

  require Logger

  @doc """
  Discovers a Redis server (primary or replica) through sentinels.

  Tries each sentinel in sequence until one successfully provides a server address.
  Returns the discovered server's host and port.

  ## Parameters

    * `sentinel_opts` - Sentinel configuration keyword list with:
      * `:sentinels` - List of sentinel nodes (required)
      * `:group` - Primary group name (required)
      * `:role` - `:primary` or `:replica` (default: `:primary`)
      * `:connect_opts` - Redix connection options for sentinels (optional)
      * `:replica_connect_opts` - Redix connection options for replica verification (optional)
      * `:host_map` - Map for translating sentinel-returned hostnames (for testing)

  ## Returns

    * `{:ok, {host, port}}` - Successfully discovered server
    * `{:error, reason}` - All sentinels failed or other error
  """
  def discover_server(sentinel_opts) do
    sentinels = Keyword.fetch!(sentinel_opts, :sentinels)
    group = Keyword.fetch!(sentinel_opts, :group)
    role = Keyword.get(sentinel_opts, :role, :primary)
    host_map = Keyword.get(sentinel_opts, :host_map, %{})

    Logger.debug("Discovering #{role} for group: #{group}")

    try_sentinels(sentinels, sentinel_opts, host_map, 1, length(sentinels))
  end

  # Tries each sentinel in the list sequentially
  defp try_sentinels([], _sentinel_opts, _host_map, _index, _total) do
    {:error, :no_viable_sentinel_connection}
  end

  defp try_sentinels([sentinel | rest], sentinel_opts, host_map, index, total) do
    host = Keyword.fetch!(sentinel, :host)
    port = Keyword.fetch!(sentinel, :port)
    group = Keyword.fetch!(sentinel_opts, :group)
    role = Keyword.get(sentinel_opts, :role, :primary)

    Logger.info("Trying sentinel #{host}:#{port} (#{index}/#{total})")

    case connect_to_sentinel(sentinel, sentinel_opts) do
      {:ok, conn} ->
        result =
          with {:ok, {server_host, server_port}} <- query_server_address(conn, group, role),
               # Map the hostname if needed (for testing)
               mapped_host = Map.get(host_map, server_host, server_host),
               :ok <- verify_role(mapped_host, server_port, role, sentinel_opts) do
            Logger.info("Verified server role: #{role}")
            {:ok, {mapped_host, server_port}}
          end

        Redix.stop(conn)

        case result do
          {:ok, _} = success ->
            success

          {:error, reason} ->
            Logger.warning("Sentinel #{host}:#{port} failed: #{inspect(reason)}, trying next")

            try_sentinels(rest, sentinel_opts, host_map, index + 1, total)
        end

      {:error, reason} ->
        Logger.warning(
          "Failed to connect to sentinel #{host}:#{port}: #{inspect(reason)}, trying next"
        )

        try_sentinels(rest, sentinel_opts, host_map, index + 1, total)
    end
  end

  # Connects to a single sentinel using Redix
  defp connect_to_sentinel(sentinel, sentinel_opts) do
    host = Keyword.fetch!(sentinel, :host)
    port = Keyword.fetch!(sentinel, :port)
    connect_opts = Keyword.get(sentinel_opts, :connect_opts, [])

    redix_opts = build_redix_opts(host, port, connect_opts)

    Logger.debug("Connecting to sentinel with opts: #{inspect(redix_opts)}")

    case Redix.start_link(redix_opts) do
      {:ok, conn} ->
        Logger.debug("Connected to sentinel successfully")
        {:ok, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Builds Redix connection options from host, port, and optional connection config
  defp build_redix_opts(host, port, opts) do
    # Start with base options
    base_opts = [
      host: to_string(host),
      port: port,
      sync_connect: true
    ]

    # Merge user-provided options, allowing them to override defaults
    # Set default timeout if not provided
    opts_with_defaults = Keyword.put_new(opts, :timeout, 500)

    Keyword.merge(base_opts, opts_with_defaults)
  end

  # Queries sentinel for server address based on role
  defp query_server_address(conn, group, :primary) do
    query_primary_address(conn, group)
  end

  defp query_server_address(conn, group, :replica) do
    query_replica_address(conn, group)
  end

  # Queries sentinel for primary address
  defp query_primary_address(conn, group) do
    Logger.debug("Querying sentinel for primary address")

    case Redix.command(conn, ["SENTINEL", "get-master-addr-by-name", group]) do
      {:ok, [host, port]} when is_binary(host) and is_binary(port) ->
        Logger.debug("Sentinel response: #{host}:#{port}")
        {:ok, {host, String.to_integer(port)}}

      {:ok, nil} ->
        Logger.debug("Sentinel returned nil - no primary found for group")
        {:error, :sentinel_no_primary_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Queries sentinel for replica address and picks one at random
  defp query_replica_address(conn, group) do
    Logger.debug("Querying sentinel for replica address")

    case Redix.command(conn, ["SENTINEL", "replicas", group]) do
      {:ok, replicas} when is_list(replicas) and replicas != [] ->
        # Parse replica info (list of lists with field-value pairs)
        case parse_and_pick_replica(replicas) do
          {:ok, {host, port}} ->
            Logger.debug("Sentinel response: picked replica #{host}:#{port}")
            {:ok, {host, port}}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, []} ->
        Logger.debug("Sentinel returned empty list - no replicas found for group")
        {:error, :sentinel_no_replicas_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Parses replica info from SENTINEL replicas response and picks one at random
  defp parse_and_pick_replica(replicas) do
    # Each replica is a list like: ["name", "...", "ip", "127.0.0.1", "port", "6380", ...]
    parsed_replicas =
      Enum.reduce(replicas, [], fn replica, acc ->
        case parse_replica(replica) do
          %{"hostname" => hostname, "port" => port} -> [{hostname, String.to_integer(port)} | acc]
          %{"ip" => ip, "port" => port} -> [{ip, String.to_integer(port)} | acc]
          _ -> acc
        end
      end)

    case parsed_replicas do
      [] ->
        {:error, :no_valid_replicas_found}

      replicas ->
        # Pick random replica
        {:ok, Enum.random(replicas)}
    end
  end

  defp parse_replica(replica_info, acc \\ %{}) do
    case replica_info do
      [key, value | rest] ->
        parse_replica(rest, Map.put(acc, key, value))

      [] ->
        acc
    end
  end

  # Verifies server role by connecting and running ROLE command
  defp verify_role(host, port, expected_role, sentinel_opts) do
    Logger.debug("Verifying server role at #{host}:#{port}")

    # Use replica_connect_opts for verification connection
    replica_connect_opts = Keyword.get(sentinel_opts, :replica_connect_opts, [])
    redix_opts = build_redix_opts(host, port, replica_connect_opts)

    case Redix.start_link(redix_opts) do
      {:ok, conn} ->
        result = check_role(conn, expected_role)
        Redix.stop(conn)
        result

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  # Checks if server role matches expected role
  defp check_role(conn, expected_role) do
    # Map role to Redis ROLE command response
    expected_role_string =
      case expected_role do
        :primary -> "master"
        :replica -> "slave"
      end

    case Redix.command(conn, ["ROLE"]) do
      {:ok, [^expected_role_string | _]} ->
        :ok

      {:ok, [actual_role | _]} ->
        Logger.warning(
          "Role verification failed: expected #{expected_role_string}, got #{actual_role}"
        )

        {:error, {:wrong_role, actual_role}}

      {:error, reason} ->
        {:error, {:role_command_failed, reason}}
    end
  end
end
