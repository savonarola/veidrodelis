defmodule Vdr.RedisStream.SentinelConnectorTest do
  use ExUnit.Case, async: false
  use CommandMatchers

  @moduletag :integration
  @moduletag :sentinel
  @moduletag :slow

  alias Vdr.RedisStream.SentinelConnector

  @sentinel_host "localhost"
  @sentinel_ports [27379, 27380, 27381]
  @sentinel_group "myprimary"
  @host_map %{
    "172.28.0.20" => "localhost",
    "172.28.0.21" => "localhost",
    "172.28.0.31" => "localhost",
    "172.28.0.32" => "localhost",
    "172.28.0.33" => "localhost"
  }

  setup_all do
    System.cmd("just", ["dc-sentinel-restart"], cd: Path.join([__DIR__, "..", "..", ".."]))
    # Wait for containers to initialize and sentinels to register replicas
    :ok
  end

  describe "discover_server/2" do
    test "successfully discovers primary from first sentinel" do
      sentinel_opts = [
        sentinels: [
          [host: @sentinel_host, port: Enum.at(@sentinel_ports, 0)]
        ],
        group: @sentinel_group,
        role: :primary,
        connect_opts: [timeout: 5000],
        replica_connect_opts: [timeout: 5000],
        host_map: @host_map
      ]

      assert_within 10_000 do
        assert {:ok, {host, port}} = SentinelConnector.discover_server(sentinel_opts)
        assert is_binary(host)
        assert is_integer(port)
        assert port > 0
      end
    end

    test "returns error when no sentinels are reachable" do
      # Trap exits to handle Redix connection errors gracefully
      Process.flag(:trap_exit, true)

      sentinel_opts = [
        sentinels: [
          [host: @sentinel_host, port: 65533],
          [host: @sentinel_host, port: 65534]
        ],
        group: @sentinel_group,
        role: :primary,
        connect_opts: [timeout: 100],
        replica_connect_opts: [timeout: 5000],
        host_map: @host_map
      ]

      assert_within 10_000 do
        assert {:error, :no_viable_sentinel_connection} =
                 SentinelConnector.discover_server(sentinel_opts)
      end
    end

    test "tries multiple sentinels on failure" do
      # Trap exits to handle Redix connection errors gracefully
      Process.flag(:trap_exit, true)

      sentinel_opts = [
        sentinels: [
          # First sentinel unreachable
          [host: @sentinel_host, port: 65534],
          # Second sentinel reachable
          [host: @sentinel_host, port: Enum.at(@sentinel_ports, 0)]
        ],
        group: @sentinel_group,
        role: :primary,
        connect_opts: [timeout: 500],
        replica_connect_opts: [timeout: 5000],
        host_map: @host_map
      ]

      assert_within 10_000 do
        # Should successfully connect through second sentinel
        assert {:ok, {host, port}} = SentinelConnector.discover_server(sentinel_opts)
        assert is_binary(host)
        assert is_integer(port)
        assert port > 0
      end
    end

    test "returns error when group doesn't exist" do
      # Trap exits to handle Redix connection errors gracefully
      Process.flag(:trap_exit, true)

      sentinel_opts = [
        sentinels: [
          [host: @sentinel_host, port: Enum.at(@sentinel_ports, 0)]
        ],
        group: "nonexistent_group",
        role: :primary,
        connect_opts: [timeout: 1000],
        replica_connect_opts: [timeout: 5000],
        host_map: @host_map
      ]

      assert_within 10_000 do
        assert {:error, :no_viable_sentinel_connection} =
                 SentinelConnector.discover_server(sentinel_opts)
      end
    end

    test "discovers replica instead of primary when role is :replica" do
      # Trap exits to handle Redix connection errors gracefully
      Process.flag(:trap_exit, true)

      sentinel_opts = [
        sentinels: [
          [host: @sentinel_host, port: Enum.at(@sentinel_ports, 0)]
        ],
        group: @sentinel_group,
        role: :replica,
        connect_opts: [timeout: 5000],
        replica_connect_opts: [timeout: 5000],
        host_map: @host_map
      ]

      assert_within 10_000 do
        assert {:ok, {host, port}} = SentinelConnector.discover_server(sentinel_opts)
        assert is_binary(host)
        assert is_integer(port)
        assert port > 0
      end
    end
  end
end
