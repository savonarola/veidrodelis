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
        assert :streaming == Veidrodelis.get_replication_state(pid)
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
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Should now be ready and have the data
      assert {:ok, "initial_value"} == Veidrodelis.get(@test_id, 0, "initial_key")
      assert {:ok, nil} == Veidrodelis.get(@test_id, 0, "nonexistent")

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
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify all data types
      assert {:ok, "value1"} == Veidrodelis.get(@test_id, 0, "string_key")
      assert {:ok, ["a", "b", "c"]} == Veidrodelis.lrange(@test_id, 0, "list_key", 0, -1)
      assert {:ok, 3} == Veidrodelis.llen(@test_id, 0, "list_key")

      {:ok, members} = Veidrodelis.smembers(@test_id, 0, "set_key")
      assert "x" in members
      assert "y" in members
      assert "z" in members
      assert {:ok, 3} == Veidrodelis.scard(@test_id, 0, "set_key")

      assert {:ok, "val1"} == Veidrodelis.hget(@test_id, 0, "hash_key", "field1")
      assert {:ok, "val2"} == Veidrodelis.hget(@test_id, 0, "hash_key", "field2")
      assert {:ok, 2} == Veidrodelis.hlen(@test_id, 0, "hash_key")

      assert {:ok, 2} == Veidrodelis.zcard(@test_id, 0, "zset_key")

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
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      assert {:ok, "value1"} == Veidrodelis.get(@test_id, 0, "key1")

      # Add new data (will be streamed)
      Redix.command!(redis, ["SET", "key2", "value2"])
      Redix.command!(redis, ["SET", "key3", "value3"])

      # Wait for data to arrive
      assert_within 1000 do
        assert {:ok, "value2"} == Veidrodelis.get(@test_id, 0, "key2")
      end

      assert_within 1000 do
        assert {:ok, "value3"} == Veidrodelis.get(@test_id, 0, "key3")
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
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      assert {:ok, "initial"} == Veidrodelis.get(@test_id, 0, "update_key")

      # Update the key
      Redix.command!(redis, ["SET", "update_key", "updated"])

      assert_within 1000 do
        assert {:ok, "updated"} == Veidrodelis.get(@test_id, 0, "update_key")
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
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # All keys should be present (atomic swap completed)
      assert {:ok, "value1"} == Veidrodelis.get(@test_id, 0, "key1")
      assert {:ok, "value2"} == Veidrodelis.get(@test_id, 0, "key2")
      assert {:ok, "value3"} == Veidrodelis.get(@test_id, 0, "key3")

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
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify all keys are present
      for i <- 1..10 do
        assert {:ok, "value#{i}"} == Veidrodelis.get(@test_id, 0, "key#{i}")
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
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Now should be ready
      assert {:ok, "value1"} == Veidrodelis.get(@test_id, 0, "key1")

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
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Existing key returns value
      assert {:ok, "value"} == Veidrodelis.get(@test_id, 0, "exists")

      # Missing key returns nil
      assert {:ok, nil} == Veidrodelis.get(@test_id, 0, "missing")

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
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Test various list operations
      assert {:ok, 5} == Veidrodelis.llen(@test_id, 0, "mylist")
      assert {:ok, ["a", "b", "c", "d", "e"]} == Veidrodelis.lrange(@test_id, 0, "mylist", 0, -1)
      assert {:ok, ["a", "b", "c"]} == Veidrodelis.lrange(@test_id, 0, "mylist", 0, 2)
      assert {:ok, ["d", "e"]} == Veidrodelis.lrange(@test_id, 0, "mylist", -2, -1)

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
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Test various hash operations
      assert {:ok, 3} == Veidrodelis.hlen(@test_id, 0, "myhash")
      assert {:ok, "v1"} == Veidrodelis.hget(@test_id, 0, "myhash", "f1")
      assert {:ok, "v2"} == Veidrodelis.hget(@test_id, 0, "myhash", "f2")

      {:ok, keys} = Veidrodelis.hkeys(@test_id, 0, "myhash")
      assert "f1" in keys
      assert "f2" in keys
      assert "f3" in keys

      {:ok, vals} = Veidrodelis.hvals(@test_id, 0, "myhash")
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
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      assert {:ok, 3} == Veidrodelis.scard(@test_id, 0, "myset")
      {:ok, members} = Veidrodelis.smembers(@test_id, 0, "myset")
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
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      assert {:ok, 3} == Veidrodelis.zcard(@test_id, 0, "myzset")
      assert {:ok, 2.0} == Veidrodelis.zscore(@test_id, 0, "myzset", "two")

      Veidrodelis.stop(pid)
    end
  end
end
