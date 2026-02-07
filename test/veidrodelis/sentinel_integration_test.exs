defmodule Vdr.SentinelIntegrationTest do
  use ExUnit.Case, async: false
  use CommandMatchers

  @moduletag :integration
  @moduletag :sentinel
  @moduletag :slow

  alias Vdr.RedisStream.Replica

  @sentinel_host "localhost"
  @sentinel_ports [27379, 27380, 27381]
  @sentinel_group "myprimary"
  @primary_host "localhost"
  @primary_port 16390

  defmodule CollectorCallback do
    @behaviour Vdr.RedisStream.Callback

    @impl Vdr.RedisStream.Callback
    def init(_opts), do: {:ok, %{commands: [], replication_starts: 0, streaming_starts: 0}}

    @impl Vdr.RedisStream.Callback
    def handle_replication_start(state) do
      new_state = Map.update!(state, :replication_starts, &(&1 + 1))
      {:ok, new_state}
    end

    @impl Vdr.RedisStream.Callback
    def handle_streaming_start(state) do
      new_state = Map.update!(state, :streaming_starts, &(&1 + 1))
      {:ok, new_state}
    end

    @impl Vdr.RedisStream.Callback
    def handle_commands(state, commands) do
      new_state = Map.update!(state, :commands, &(commands ++ &1))
      {:ok, new_state}
    end

    @impl Vdr.RedisStream.Callback
    def handle_call(state, {:get_test_state}), do: {:reply, state, state}

    @impl Vdr.RedisStream.Callback
    def handle_call(state, _message), do: {:reply, :ok, state}

    @impl Vdr.RedisStream.Callback
    def handle_info(state, _message), do: {:noreply, state}

    @impl Vdr.RedisStream.Callback
    def handle_destroy(_state), do: :ok

    def get_state(pid) do
      Vdr.RedisStream.Replica.call(pid, {:get_test_state})
    end
  end

  setup do
    System.cmd("just", ["dc-sentinel-restart"], cd: Path.join([__DIR__, "..", ".."]))
    # Connect to primary directly to set up test data
    {:ok, conn} = Redix.start_link(host: @primary_host, port: @primary_port)

    # Flush all data and wait for it to propagate
    Redix.command!(conn, ["FLUSHALL"])

    log_level = Logger.level()
    Logger.configure(level: :critical)

    on_exit(fn ->
      Logger.configure(level: log_level)
    end)

    %{conn: conn}
  end

  describe "sentinel discovery" do
    test "discovers primary via sentinel", %{conn: conn} do
      # Set up some test data
      Redix.command!(conn, ["SET", "sentinel_test_key", "sentinel_test_value"])

      # Start replica via sentinel
      opts = [
        sentinel: [
          sentinels: [
            [host: @sentinel_host, port: Enum.at(@sentinel_ports, 0)],
            [host: @sentinel_host, port: Enum.at(@sentinel_ports, 1)],
            [host: @sentinel_host, port: Enum.at(@sentinel_ports, 2)]
          ],
          group: @sentinel_group,
          role: :primary,
          connect_opts: [timeout: 1000],
          host_map: fn _host -> "localhost" end
        ],
        callback_module: CollectorCallback,
        callback_opts: []
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for replication to start
      assert_within 5000 do
        assert {:ok, state} = CollectorCallback.get_state(replica)
        assert state.replication_starts > 0
        assert state.streaming_starts > 0
      end

      # Issue a new command
      Redix.command!(conn, ["SET", "streaming_key", "streaming_value"])

      # Wait for streaming command
      assert_within 2000 do
        assert {:ok, state} = CollectorCallback.get_state(replica)

        assert command_in_list(
                 %Vdr.RedisStream.ReplicaCommand{
                   command: {:set, "streaming_key", "streaming_value"}
                 },
                 state.commands
               )
      end

      Replica.stop(replica)
    end

    test "discovers primary from second sentinel if first fails" do
      # Start replica with first sentinel on invalid port
      opts = [
        sentinel: [
          sentinels: [
            # Unreachable sentinel
            [host: @sentinel_host, port: 65534],
            # Valid sentinel
            [host: @sentinel_host, port: Enum.at(@sentinel_ports, 0)]
          ],
          group: @sentinel_group,
          role: :primary,
          connect_opts: [timeout: 500],
          host_map: fn _host -> "localhost" end
        ],
        callback_module: CollectorCallback,
        callback_opts: []
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Should discover primary from second sentinel
      assert_within 5000 do
        assert {:ok, state} = CollectorCallback.get_state(replica)
        assert state.replication_starts > 0
      end

      Replica.stop(replica)
    end

    test "connects to discovered server and replicates data", %{conn: conn} do
      # Set up diverse test data
      Redix.command!(conn, ["SET", "string_key", "value"])
      Redix.command!(conn, ["RPUSH", "list_key", "item1", "item2"])
      Redix.command!(conn, ["SADD", "set_key", "member1", "member2"])
      Redix.command!(conn, ["ZADD", "zset_key", "1", "member1", "2", "member2"])
      Redix.command!(conn, ["HSET", "hash_key", "field1", "value1", "field2", "value2"])
      Redix.command!(conn, ["SAVE"])

      # Start replica via sentinel
      opts = [
        sentinel: [
          sentinels:
            Enum.map(@sentinel_ports, fn port ->
              [host: @sentinel_host, port: port]
            end),
          group: @sentinel_group,
          role: :primary,
          host_map: fn _host -> "localhost" end
        ],
        callback_module: CollectorCallback,
        callback_opts: []
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for full sync and streaming
      assert_within 5000 do
        assert {:ok, state} = CollectorCallback.get_state(replica)
        assert state.streaming_starts > 0
      end

      # Issue streaming commands
      Redix.command!(conn, ["SET", "stream1", "value1"])
      Redix.command!(conn, ["SET", "stream2", "value2"])

      # Verify streaming commands received
      assert_within 2000 do
        assert {:ok, state} = CollectorCallback.get_state(replica)

        assert command_in_list(
                 %Vdr.RedisStream.ReplicaCommand{command: {:set, "stream1", "value1"}},
                 state.commands
               )

        assert command_in_list(
                 %Vdr.RedisStream.ReplicaCommand{command: {:set, "stream2", "value2"}},
                 state.commands
               )
      end

      Replica.stop(replica)
    end
  end

  describe "failover" do
    test "reconnects to another replica when connected replica fails", %{conn: conn} do
      # Set up test data on primary
      Redix.command!(conn, ["SET", "before_replica_failure", "value1"])
      Process.sleep(1000)
      Redix.command!(conn, ["SAVE"])

      # Start Veidrodelis replica connecting to a Redis replica via sentinel
      opts = [
        sentinel: [
          sentinels:
            Enum.map(@sentinel_ports, fn port ->
              [host: @sentinel_host, port: port]
            end),
          group: @sentinel_group,
          role: :replica,
          host_map: fn _host -> "localhost" end
        ],
        callback_module: CollectorCallback,
        callback_opts: []
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for initial replication
      assert_within 5000 do
        assert {:ok, state} = CollectorCallback.get_state(replica)
        assert state.streaming_starts > 0
      end

      # Issue a command before replica failure
      Redix.command!(conn, ["SET", "pre_replica_failure", "test"])

      # Wait for the command to be replicated
      assert_within 2000 do
        assert {:ok, state} = CollectorCallback.get_state(replica)

        assert command_in_list(
                 %Vdr.RedisStream.ReplicaCommand{command: {:set, "pre_replica_failure", "test"}},
                 state.commands
               )
      end

      # Get the connected replica host and port
      {:ok, {_connected_host, connected_port}} = Replica.connected_to(replica)

      # Map port to container name
      replica_container =
        case connected_port do
          16391 -> "veidrodelis-sentinel-replica-1"
          16392 -> "veidrodelis-sentinel-replica-2"
          _ -> raise "Unknown replica port: #{connected_port}"
        end

      # Stop the connected replica
      {_output, 0} = System.cmd("docker", ["stop", replica_container])

      # Register cleanup to restore replica
      on_exit(fn ->
        {_output, 0} = System.cmd("docker", ["start", replica_container])
        # Wait for replica to be back up
        Process.sleep(2000)
      end)

      # Wait a moment for sentinel and Veidrodelis to detect the failure
      Process.sleep(2000)

      # Issue a new command to the primary after replica failure
      Redix.command!(conn, ["SET", "after_replica_failure", "value2"])

      # Wait for the command to be replicated through the new replica
      assert_within 10_000 do
        assert {:ok, state} = CollectorCallback.get_state(replica)

        assert command_in_list(
                 %Vdr.RedisStream.ReplicaCommand{
                   command: {:set, "after_replica_failure", "value2"}
                 },
                 state.commands
               )
      end

      # Verify we're now connected to a different replica
      {:ok, {_new_host, new_port}} = Replica.connected_to(replica)
      assert new_port != connected_port, "Should be connected to a different replica"

      # Verify replica is still receiving commands
      Redix.command!(conn, ["SET", "final_replica_test", "success"])

      assert_within 2000 do
        assert {:ok, state} = CollectorCallback.get_state(replica)

        assert command_in_list(
                 %Vdr.RedisStream.ReplicaCommand{
                   command: {:set, "final_replica_test", "success"}
                 },
                 state.commands
               )
      end

      Replica.stop(replica)
    end

    test "reconnects to new primary after failover", %{conn: conn} do
      # Set up test data
      Redix.command!(conn, ["SET", "before_failover", "value1"])
      Process.sleep(1000)
      Redix.command!(conn, ["SAVE"])

      # Start replica via sentinel
      opts = [
        sentinel: [
          sentinels:
            Enum.map(@sentinel_ports, fn port ->
              [host: @sentinel_host, port: port]
            end),
          group: @sentinel_group,
          role: :primary,
          host_map: fn _host -> "localhost" end
        ],
        callback_module: CollectorCallback,
        callback_opts: []
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for initial replication
      assert_within 5000 do
        assert {:ok, state} = CollectorCallback.get_state(replica)
        assert state.streaming_starts > 0
      end

      # Issue a command before failover
      Redix.command!(conn, ["SET", "pre_failover", "test"])

      # Wait for the command to be replicated
      assert_within 2000 do
        assert {:ok, state} = CollectorCallback.get_state(replica)

        assert command_in_list(
                 %Vdr.RedisStream.ReplicaCommand{command: {:set, "pre_failover", "test"}},
                 state.commands
               )
      end

      # Trigger failover by stopping the primary
      {_output, 0} = System.cmd("docker", ["stop", "veidrodelis-sentinel-primary"])

      # Register cleanup to restore primary
      on_exit(fn ->
        {_output, 0} = System.cmd("docker", ["start", "veidrodelis-sentinel-primary"])
        # Wait for primary to be back up
        Process.sleep(2000)
      end)

      # Wait for sentinel to complete failover and promote replica
      new_primary_result = :erlang.make_ref()

      assert_within 60_000 do
        # Query sentinel using Redix
        {:ok, sentinel_conn} =
          Redix.start_link(
            host: @sentinel_host,
            port: Enum.at(@sentinel_ports, 0),
            timeout: 5_000,
            sync_connect: true
          )

        result =
          Redix.command(sentinel_conn, ["SENTINEL", "get-master-addr-by-name", @sentinel_group],
            timeout: 5_000
          )

        Redix.stop(sentinel_conn)

        case result do
          {:ok, [_host, port_str]} ->
            port = String.to_integer(port_str)

            # Skip if sentinel still reports the old primary
            if port == @primary_port do
              Process.sleep(1000)
              raise "Sentinel still reports old primary"
            end

            # Sentinel returns the IP address, map it to localhost
            mapped_host = "localhost"

            # Verify it's actually writable (promoted to primary)
            case Redix.start_link(
                   host: mapped_host,
                   port: port,
                   timeout: 5_000,
                   sync_connect: true
                 ) do
              {:ok, test_conn} ->
                # Check role
                role_result = Redix.command(test_conn, ["ROLE"], timeout: 5_000)

                # Try a test write to confirm it's writable
                write_result =
                  Redix.command(test_conn, ["SET", "failover_test", "ok"], timeout: 5_000)

                Redix.stop(test_conn)

                case {role_result, write_result} do
                  {{:ok, ["master" | _]}, {:ok, "OK"}} ->
                    # Store result for later use
                    Process.put(new_primary_result, {mapped_host, port})
                    :ok

                  {{:ok, ["master" | _]}, _} ->
                    Process.sleep(1000)
                    raise "Primary but not writable yet"

                  _ ->
                    Process.sleep(1000)
                    raise "Not a primary yet"
                end

              {:error, reason} ->
                Process.sleep(1000)
                raise "Cannot connect: #{inspect(reason)}"
            end

          {:error, reason} ->
            Process.sleep(1000)
            raise "Sentinel query failed: #{inspect(reason)}"

          _ ->
            Process.sleep(1000)
            raise "Invalid sentinel response: #{inspect(result)}"
        end
      end

      # Retrieve the stored result
      {new_primary_host, new_primary_port} = Process.get(new_primary_result)

      # Connect to the new primary
      {:ok, new_primary_conn} = Redix.start_link(host: new_primary_host, port: new_primary_port)

      # Issue a command to the new primary
      Redix.command!(new_primary_conn, ["SET", "after_failover", "value2"])

      # Wait for the new command to be replicated to our Veidrodelis replica
      assert_within 5000 do
        assert {:ok, state} = CollectorCallback.get_state(replica)

        assert command_in_list(
                 %Vdr.RedisStream.ReplicaCommand{command: {:set, "after_failover", "value2"}},
                 state.commands
               )
      end

      # Verify replica is still receiving commands from the new primary
      Redix.command!(new_primary_conn, ["SET", "final_test", "success"])

      assert_within 2000 do
        assert {:ok, state} = CollectorCallback.get_state(replica)

        assert command_in_list(
                 %Vdr.RedisStream.ReplicaCommand{command: {:set, "final_test", "success"}},
                 state.commands
               )
      end

      Redix.stop(new_primary_conn)
      Replica.stop(replica)
    end
  end

  describe "error handling" do
    test "returns error when all sentinels are unreachable" do
      # Trap exits so we can observe the failure without crashing the test
      Process.flag(:trap_exit, true)

      opts = [
        sentinel: [
          sentinels: [
            [host: @sentinel_host, port: 65533],
            [host: @sentinel_host, port: 65534]
          ],
          group: @sentinel_group,
          role: :primary,
          connect_opts: [timeout: 100],
          host_map: fn _host -> "localhost" end
        ],
        callback_module: CollectorCallback,
        callback_opts: [],
        # Disable reconnection for this test
        reconnect: false
      ]

      # Should fail to start since sentinels are unreachable
      {:ok, replica} = Replica.start_link(opts)

      # Wait for the replica to fail
      assert_receive {:EXIT, ^replica,
                      {:connection_failed,
                       {:sentinel_discovery_failed, :no_viable_sentinel_connection}}},
                     1000
    end

    test "returns error when group doesn't exist" do
      # Trap exits so we can observe the failure without crashing the test
      Process.flag(:trap_exit, true)

      opts = [
        sentinel: [
          sentinels:
            Enum.map(@sentinel_ports, fn port ->
              [host: @sentinel_host, port: port]
            end),
          group: "nonexistent_group",
          role: :primary,
          connect_opts: [timeout: 1000],
          host_map: fn _host -> "localhost" end
        ],
        callback_module: CollectorCallback,
        callback_opts: [],
        reconnect: false
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for the replica to fail
      assert_receive {:EXIT, ^replica,
                      {:connection_failed,
                       {:sentinel_discovery_failed, :no_viable_sentinel_connection}}},
                     2000
    end
  end
end
