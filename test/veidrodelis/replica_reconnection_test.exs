defmodule Veidrodelis.ReplicaReconnectionTest do
  use ExUnit.Case, async: false

  alias Veidrodelis.RedisStream.Replica
  alias Veidrodelis.Command
  alias Veidrodelis.Test.Toxiproxy
  use CommandMatchers

  # Callback module that collects all commands
  defmodule CollectorCallback do
    @behaviour Veidrodelis.RedisStream.Callback

    @impl true
    def on_command(state, db, command) do
      # Add command to the list with timestamp
      commands = Map.get(state, :commands, [])
      entry = {System.monotonic_time(), db, command}
      new_state = Map.put(state, :commands, [entry | commands])
      {:ok, new_state}
    end

    @impl true
    def on_replication_start(state) do
      # Mark that replication has started
      replication_starts = Map.get(state, :replication_starts, 0)
      new_state = Map.put(state, :replication_starts, replication_starts + 1)
      {:ok, new_state}
    end

    def commands(state) do
      Map.get(state, :commands, [])
      |> Enum.map(fn {_ts, _db, cmd} -> cmd end)
      |> Enum.reverse()
    end

    def replication_starts(state) do
      Map.get(state, :replication_starts, 0)
    end
  end

  @redis_host "localhost"
  @redis_port 16379

  setup do
    # Ensure Toxiproxy is available
    :ok = Toxiproxy.wait_until_ready()

    # Reset toxiproxy to clean state
    :ok = Toxiproxy.reset("redis")

    # Connect to Redis for test setup (through toxiproxy)
    {:ok, redis} = Redix.start_link(host: @redis_host, port: @redis_port)

    # Flush all databases before each test
    Redix.command!(redis, ["FLUSHALL"])

    on_exit(fn ->
      # Reset toxiproxy
      Toxiproxy.reset("redis")

      if Process.alive?(redis) do
        Redix.stop(redis)
      end
    end)

    {:ok, redis: redis}
  end

  describe "connection failure and reconnection" do
    test "reconnects after connection break", %{redis: redis} do
      # Write initial data
      Redix.command!(redis, ["SET", "before_disconnect", "value1"])

      # Start replica
      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: []},
        reconnect_delay_ms: 500,
        max_reconnect_delay_ms: 1000
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for initial sync
      assert_happens_within 1500 do
        Replica.get_replication_state(replica) == :streaming
      end

      # Verify initial command was received
      callback_state = Replica.get_callback_state(replica)
      commands = CollectorCallback.commands(callback_state)

      assert_command_in_list(%Command.Set{key: "before_disconnect", value: "value1"}, commands)

      # Break connection
      :ok = Toxiproxy.break_connection("redis")

      # Wait for disconnection to be detected
      Process.sleep(1000)

      # Restore connection
      :ok = Toxiproxy.restore_connection("redis")

      # Wait longer for both replica and redix to reconnect and stabilize
      assert_happens_within 5000 do
        Replica.get_replication_state(replica) == :streaming
      end

      # Write new data after reconnection - use fresh connection
      {:ok, redis_new} = Redix.start_link(host: @redis_host, port: @redis_port)
      Redix.command!(redis_new, ["SET", "after_reconnect", "value2"])
      # Force a command to go through
      Redix.command!(redis_new, ["PING"])
      Redix.stop(redis_new)

      # Wait for replication to process
      assert_happens_within 2000 do
        callback_state = Replica.get_callback_state(replica)
        commands = CollectorCallback.commands(callback_state)
        assert_command_in_list(%Command.Set{key: "after_reconnect", value: "value2"}, commands)
      end

      Replica.stop(replica)
    end

    test "calls on_replication_start callback on initial connect", %{redis: redis} do
      # Write initial data
      Redix.command!(redis, ["SET", "key1", "value1"])

      # Start replica
      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: [], replication_starts: 0},
        reconnect_delay_ms: 500
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for initial sync
      assert_happens_within 1500 do
        Replica.get_replication_state(replica) == :streaming
      end

      # Check that on_replication_start was called once on initial full sync
      callback_state = Replica.get_callback_state(replica)
      assert 1 == CollectorCallback.replication_starts(callback_state)

      Replica.stop(replica)
    end

    test "does not call on_replication_start on partial resync", %{redis: redis} do
      # Write initial data
      Redix.command!(redis, ["SET", "key1", "value1"])

      # Start replica
      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: [], replication_starts: 0},
        reconnect_delay_ms: 500
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for initial sync
      assert_happens_within 1500 do
        Replica.get_replication_state(replica) == :streaming
      end

      # Check that on_replication_start was called once
      callback_state = Replica.get_callback_state(replica)
      assert 1 == CollectorCallback.replication_starts(callback_state)

      # Break and restore connection quickly (should trigger partial resync)
      :ok = Toxiproxy.break_connection("redis")
      Process.sleep(200)
      :ok = Toxiproxy.restore_connection("redis")

      # Wait for reconnection
      assert_happens_within 2000 do
        Replica.get_replication_state(replica) == :streaming
      end

      # on_replication_start should NOT be called again for partial resync
      callback_state = Replica.get_callback_state(replica)
      assert Map.get(callback_state, :replication_starts) == 1

      Replica.stop(replica)
    end

    test "retries with exponential backoff on connection failure", %{redis: _redis} do
      # Disable the proxy completely
      :ok = Toxiproxy.disable("redis")

      # Start replica with fast retry
      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: []},
        reconnect_delay_ms: 100,
        max_reconnect_delay_ms: 1000
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for several retry attempts
      Process.sleep(500)

      # Replica should still be alive and retrying
      assert Process.alive?(replica)

      # Re-enable the proxy
      :ok = Toxiproxy.enable("redis")

      # Wait for successful connection
      assert_happens_within 2000 do
        Replica.get_replication_state(replica) == :streaming
      end

      # Replica should still be alive
      assert Process.alive?(replica)

      Replica.stop(replica)
    end

    test "handles temporary network outage", %{redis: redis} do
      # Write initial data
      Redix.command!(redis, ["SET", "before_outage", "value1"])

      # Start replica
      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: []},
        reconnect_delay_ms: 500
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for initial sync
      assert_happens_within 1500 do
        Replica.get_replication_state(replica) == :streaming
      end

      # Simulate 2-second network outage
      :ok = Toxiproxy.simulate_outage("redis", 2000)

      # Wait for reconnection
      assert_happens_within 5000 do
        Replica.get_replication_state(replica) == :streaming
      end

      # Write new data - use fresh connection
      {:ok, redis_new} = Redix.start_link(host: @redis_host, port: @redis_port)
      Redix.command!(redis_new, ["SET", "after_outage", "value2"])
      Redix.command!(redis_new, ["PING"])
      Redix.stop(redis_new)

      # Wait for replication
      assert_happens_within 2000 do
        callback_state = Replica.get_callback_state(replica)
        commands = CollectorCallback.commands(callback_state)
        assert_command_in_list(%Command.Set{key: "after_outage"}, commands)
      end

      # Verify we received both commands
      callback_state = Replica.get_callback_state(replica)
      commands = CollectorCallback.commands(callback_state)

      assert_command_in_list(%Command.Set{key: "before_outage", value: "value1"}, commands)
      assert_command_in_list(%Command.Set{key: "after_outage", value: "value2"}, commands)

      Replica.stop(replica)
    end
  end

  describe "replication offset tracking across reconnections" do
    test "maintains offset across reconnections", %{redis: redis} do
      # Write initial data
      Redix.command!(redis, ["SET", "key1", "value1"])

      # Start replica
      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: CollectorCallback,
        callback_state: %{commands: []},
        reconnect_delay_ms: 500
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for initial sync
      assert_happens_within 1500 do
        Replica.get_replication_state(replica) == :streaming
      end

      # Get initial offset
      initial_offset = Replica.get_offset(replica)
      assert initial_offset > 0

      # Break and restore connection
      :ok = Toxiproxy.break_connection("redis")
      Process.sleep(500)
      :ok = Toxiproxy.restore_connection("redis")

      # Wait for reconnection
      assert_happens_within 2000 do
        Replica.get_replication_state(replica) == :streaming
      end

      # Offset should be preserved or increased
      final_offset = Replica.get_offset(replica)
      assert final_offset >= initial_offset

      Replica.stop(replica)
    end
  end
end
