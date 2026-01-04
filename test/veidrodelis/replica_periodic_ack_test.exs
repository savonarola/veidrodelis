defmodule Veidrodelis.ReplicaPeriodicAckTest do
  use ExUnit.Case, async: false

  @moduletag :slow

  alias Vdr.RedisStream.Replica
  use CommandMatchers

  # Simple callback that does nothing
  defmodule NoOpCallback do
    @behaviour Vdr.RedisStream.Callback

    @impl true
    def init(_opts) do
      {:ok, %{}}
    end

    @impl true
    def handle_replication_start(state) do
      {:ok, state}
    end

    @impl true
    def handle_streaming_start(state) do
      {:ok, state}
    end

    @impl true
    def handle_command(state, %Vdr.RedisStream.ReplicaCommand{}) do
      {:ok, state}
    end
  end

  @redis_host "localhost"
  @redis_port 16378

  setup do
    # Ensure Redis is running
    {:ok, redis} = Redix.start_link(host: @redis_host, port: @redis_port)
    Redix.command!(redis, ["FLUSHALL"])

    on_exit(fn ->
      if Process.alive?(redis) do
        Redix.stop(redis)
      end
    end)

    {:ok, redis: redis}
  end

  describe "periodic ACK" do
    test "sends periodic REPLCONF ACK at configured interval", %{redis: redis} do
      # Write some initial data
      Redix.command!(redis, ["SET", "key1", "value1"])

      # Start replica with 500ms ACK interval
      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: NoOpCallback,
        callback_state: %{},
        ack_interval_ms: 500
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for replica to reach streaming state
      assert_within 2000 do
        assert :streaming == Replica.get_replication_state(replica)
      end

      initial_offset = Replica.get_offset(replica)

      # Write more data to trigger offset updates
      Redix.command!(redis, ["SET", "key2", "value2"])
      Redix.command!(redis, ["SET", "key3", "value3"])

      # Wait for ACK interval to pass multiple times (1.5 seconds = ~3 ACKs)
      Process.sleep(1500)

      # Verify replica is still connected and offset has increased
      final_offset = Replica.get_offset(replica)
      assert final_offset > initial_offset

      # The replica should still be in streaming state
      assert :streaming == Replica.get_replication_state(replica)

      Replica.stop(replica)
    end

    test "uses default 1000ms ACK interval when not configured", %{redis: redis} do
      # Write some initial data
      Redix.command!(redis, ["SET", "key1", "value1"])

      # Start replica without specifying ack_interval_ms (should default to 1000ms)
      opts = [
        host: @redis_host,
        port: @redis_port,
        callback_module: NoOpCallback,
        callback_state: %{}
      ]

      {:ok, replica} = Replica.start_link(opts)

      # Wait for replica to reach streaming state
      assert_within 2000 do
        assert :streaming == Replica.get_replication_state(replica)
      end

      # Write more data
      Redix.command!(redis, ["SET", "key2", "value2"])

      # Wait for at least one ACK interval
      Process.sleep(1200)

      # Verify replica is still connected
      assert :streaming == Replica.get_replication_state(replica)

      Replica.stop(replica)
    end
  end
end
