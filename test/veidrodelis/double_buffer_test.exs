defmodule Veidrodelis.DoubleBufferTest do
  @moduledoc """
  Tests for Veidrodelis double-buffering functionality:
  - Initial state returns :not_ready
  - RDB transfer to new_store while serving reads from old store
  - Atomic swap on streaming start
  - Continued operation after reconnection
  """

  use ExUnit.Case, async: false
  use CommandMatchers

  @redis_host "localhost"
  @redis_port 16378
  @test_id :double_buffer_test

  setup do
    # Ensure Redis is running and flush all data
    {:ok, redis} = Redix.start_link(host: @redis_host, port: @redis_port)
    Redix.command!(redis, ["FLUSHALL"])

    %{redis: redis}
  end

  describe "initial state" do
    test "returns error before first streaming starts", %{redis: _redis} do
      # Start Veidrodelis instance
      {:ok, pid} =
        Veidrodelis.start_link(
          id: @test_id,
          host: @redis_host,
          port: @redis_port
        )

      # Immediately try to read - should get error (either :not_connected or :not_ready)
      result = Veidrodelis.get(@test_id, 0, "test_key")
      assert result in [{:error, :not_connected}, {:error, :not_ready}]

      # Wait for streaming to start
      assert_within 1500 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      Veidrodelis.stop(pid)
    end
  end

  describe "first replication" do
    test "becomes ready after RDB transfer and streaming starts", %{redis: redis} do
      # Set up some data in Redis
      Redix.command!(redis, ["SET", "initial_key", "initial_value"])

      # Start Veidrodelis instance
      {:ok, pid} =
        Veidrodelis.start_link(
          id: @test_id,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for streaming to start
      assert_within 1500 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Should now be ready and have the data
      assert Veidrodelis.get(@test_id, 0, "initial_key") == "initial_value"
      assert Veidrodelis.get(@test_id, 0, "nonexistent") == nil

      Veidrodelis.stop(pid)
    end

    test "processes RDB data correctly", %{redis: redis} do
      # Set up diverse data types in Redis
      Redix.command!(redis, ["SET", "string_key", "value1"])
      Redix.command!(redis, ["RPUSH", "list_key", "a", "b", "c"])
      Redix.command!(redis, ["SADD", "set_key", "x", "y", "z"])
      Redix.command!(redis, ["HSET", "hash_key", "field1", "val1", "field2", "val2"])
      Redix.command!(redis, ["ZADD", "zset_key", "1.0", "member1", "2.0", "member2"])

      # Start Veidrodelis instance
      {:ok, pid} =
        Veidrodelis.start_link(
          id: @test_id,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for streaming
      assert_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify all data types
      assert Veidrodelis.get(@test_id, 0, "string_key") == "value1"
      assert Veidrodelis.lrange(@test_id, 0, "list_key", 0, -1) == ["a", "b", "c"]
      assert Veidrodelis.llen(@test_id, 0, "list_key") == 3

      members = Veidrodelis.smembers(@test_id, 0, "set_key")
      assert "x" in members
      assert "y" in members
      assert "z" in members
      assert Veidrodelis.scard(@test_id, 0, "set_key") == 3

      assert Veidrodelis.hget(@test_id, 0, "hash_key", "field1") == "val1"
      assert Veidrodelis.hget(@test_id, 0, "hash_key", "field2") == "val2"
      assert Veidrodelis.hlen(@test_id, 0, "hash_key") == 2

      assert Veidrodelis.zcard(@test_id, 0, "zset_key") == 2

      Veidrodelis.stop(pid)
    end
  end

  describe "streaming mode" do
    test "processes streaming commands after RDB", %{redis: redis} do
      # Set initial data
      Redix.command!(redis, ["SET", "key1", "value1"])

      # Start Veidrodelis instance
      {:ok, pid} =
        Veidrodelis.start_link(
          id: @test_id,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for streaming
      assert_within 1500 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      assert Veidrodelis.get(@test_id, 0, "key1") == "value1"

      # Add new data (will be streamed)
      Redix.command!(redis, ["SET", "key2", "value2"])
      Redix.command!(redis, ["SET", "key3", "value3"])

      # Wait for data to arrive
      assert_within 1000 do
        Veidrodelis.get(@test_id, 0, "key2") == "value2"
      end

      assert_within 1000 do
        Veidrodelis.get(@test_id, 0, "key3") == "value3"
      end

      Veidrodelis.stop(pid)
    end

    test "updates existing keys via streaming", %{redis: redis} do
      # Set initial data
      Redix.command!(redis, ["SET", "update_key", "initial"])

      # Start Veidrodelis
      {:ok, pid} =
        Veidrodelis.start_link(
          id: @test_id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 1500 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      assert Veidrodelis.get(@test_id, 0, "update_key") == "initial"

      # Update the key
      Redix.command!(redis, ["SET", "update_key", "updated"])

      assert_within 1000 do
        Veidrodelis.get(@test_id, 0, "update_key") == "updated"
      end

      Veidrodelis.stop(pid)
    end
  end

  describe "consistency during transition" do
    test "atomic swap ensures no partial data visible", %{redis: redis} do
      # Set up a multi-key dataset
      Redix.command!(redis, ["SET", "key1", "value1"])
      Redix.command!(redis, ["SET", "key2", "value2"])
      Redix.command!(redis, ["SET", "key3", "value3"])

      {:ok, pid} =
        Veidrodelis.start_link(
          id: @test_id,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for streaming
      assert_within 1500 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # All keys should be present (atomic swap completed)
      assert Veidrodelis.get(@test_id, 0, "key1") == "value1"
      assert Veidrodelis.get(@test_id, 0, "key2") == "value2"
      assert Veidrodelis.get(@test_id, 0, "key3") == "value3"

      Veidrodelis.stop(pid)
    end

    test "no data loss during RDB to streaming transition", %{redis: redis} do
      # Set up initial data
      for i <- 1..10 do
        Redix.command!(redis, ["SET", "key#{i}", "value#{i}"])
      end

      {:ok, pid} =
        Veidrodelis.start_link(
          id: @test_id,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for streaming
      assert_within 1500 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify all keys are present
      for i <- 1..10 do
        assert Veidrodelis.get(@test_id, 0, "key#{i}") == "value#{i}"
      end

      Veidrodelis.stop(pid)
    end
  end

  describe "error handling" do
    test "maintains error state until first streaming", %{redis: redis} do
      # Set data before starting replica
      Redix.command!(redis, ["SET", "key1", "value1"])

      # Start Veidrodelis
      {:ok, pid} =
        Veidrodelis.start_link(
          id: @test_id,
          host: @redis_host,
          port: @redis_port
        )

      # Immediately check - should get error (either :not_connected or :not_ready)
      result = Veidrodelis.get(@test_id, 0, "key1")
      assert result in [{:error, :not_connected}, {:error, :not_ready}]

      # Wait for streaming
      assert_within 1500 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Now should be ready
      assert Veidrodelis.get(@test_id, 0, "key1") == "value1"

      Veidrodelis.stop(pid)
    end

    test "handles missing keys gracefully", %{redis: redis} do
      Redix.command!(redis, ["SET", "exists", "value"])

      {:ok, pid} =
        Veidrodelis.start_link(
          id: @test_id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 1500 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Existing key returns value
      assert Veidrodelis.get(@test_id, 0, "exists") == "value"

      # Missing key returns nil
      assert Veidrodelis.get(@test_id, 0, "missing") == nil

      Veidrodelis.stop(pid)
    end
  end

  describe "multiple data types" do
    test "handles complex list operations", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "mylist", "a", "b", "c", "d", "e"])

      {:ok, pid} =
        Veidrodelis.start_link(
          id: @test_id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 1500 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Test various list operations
      assert Veidrodelis.llen(@test_id, 0, "mylist") == 5
      assert Veidrodelis.lrange(@test_id, 0, "mylist", 0, -1) == ["a", "b", "c", "d", "e"]
      assert Veidrodelis.lrange(@test_id, 0, "mylist", 0, 2) == ["a", "b", "c"]
      assert Veidrodelis.lrange(@test_id, 0, "mylist", -2, -1) == ["d", "e"]

      Veidrodelis.stop(pid)
    end

    test "handles complex hash operations", %{redis: redis} do
      Redix.command!(redis, ["HSET", "myhash", "f1", "v1", "f2", "v2", "f3", "v3"])

      {:ok, pid} =
        Veidrodelis.start_link(
          id: @test_id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 1500 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Test various hash operations
      assert Veidrodelis.hlen(@test_id, 0, "myhash") == 3
      assert Veidrodelis.hget(@test_id, 0, "myhash", "f1") == "v1"
      assert Veidrodelis.hget(@test_id, 0, "myhash", "f2") == "v2"

      keys = Veidrodelis.hkeys(@test_id, 0, "myhash")
      assert "f1" in keys
      assert "f2" in keys
      assert "f3" in keys

      vals = Veidrodelis.hvals(@test_id, 0, "myhash")
      assert "v1" in vals
      assert "v2" in vals
      assert "v3" in vals

      Veidrodelis.stop(pid)
    end

    test "handles set operations", %{redis: redis} do
      Redix.command!(redis, ["SADD", "myset", "m1", "m2", "m3"])

      {:ok, pid} =
        Veidrodelis.start_link(
          id: @test_id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 1500 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      assert Veidrodelis.scard(@test_id, 0, "myset") == 3
      members = Veidrodelis.smembers(@test_id, 0, "myset")
      assert "m1" in members
      assert "m2" in members
      assert "m3" in members

      Veidrodelis.stop(pid)
    end

    test "handles sorted set operations", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "myzset", "1.0", "one", "2.0", "two", "3.0", "three"])

      {:ok, pid} =
        Veidrodelis.start_link(
          id: @test_id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 1500 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      assert Veidrodelis.zcard(@test_id, 0, "myzset") == 3
      assert Veidrodelis.zscore(@test_id, 0, "myzset", "two") == 2.0

      Veidrodelis.stop(pid)
    end
  end
end
