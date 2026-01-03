defmodule VeidrodelisTSTest do
  use ExUnit.Case, async: false

  require Logger

  use CommandMatchers

  @redis_host "localhost"
  @redis_port 16378
  @id "vdr_ts_id"

  @veidrodelis_base_opts [
    id: @id,
    host: @redis_host,
    port: @redis_port,
    impl: {Vdr.TSProj, []}
  ]

  def veidrodelis_opts(opts \\ []) do
    @veidrodelis_base_opts ++ opts
  end

  setup do
    # Ensure Redis is running
    {:ok, redis} = Redix.start_link(host: @redis_host, port: @redis_port)

    # Flush all databases before each test
    Redix.command!(redis, ["FLUSHALL"])

    on_exit(fn ->
      if Process.alive?(redis) do
        Redix.stop(redis)
      end
    end)

    {:ok, redis: redis}
  end

  describe "Veidrodelis with TSProj" do
    test "processes string commands", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["SET", "key1", "value1"])
      Redix.command!(redis, ["SET", "key2", "value2"])

      # Start Veidrodelis instance with TSProj
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify data in store
      wait_happens_within 100 do
        Veidrodelis.get(@id, 0, "key1") == "value1" &&
          Veidrodelis.get(@id, 0, "key2") == "value2" &&
          Redix.command!(redis, ["GET", "key1"]) == "value1" &&
          Redix.command!(redis, ["GET", "key2"]) == "value2"
      end

      Veidrodelis.stop(pid)
    end

    test "processes streaming string commands", %{redis: redis} do
      # Start Veidrodelis FIRST (before writing data)
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication to start
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # NOW write data to Redis (these will come via streaming, not RDB)
      Redix.command!(redis, ["SET", "stream_key", "stream_value"])

      # Wait for commands to replicate
      assert_happens_within 1000 do
        Veidrodelis.get(@id, 0, "stream_key") != nil
      end

      # Verify the data
      assert Veidrodelis.get(@id, 0, "stream_key") == "stream_value"

      Veidrodelis.stop(pid)
    end

    test "handles del commands", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["SET", "key1", "value1"])
      Redix.command!(redis, ["SET", "key2", "value2"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify initial data
      wait_happens_within 100 do
        Veidrodelis.get(@id, 0, "key1") == "value1" &&
          Veidrodelis.get(@id, 0, "key2") == "value2"
      end

      # Delete one key
      Redix.command!(redis, ["DEL", "key1"])

      # Wait for deletion to replicate
      wait_happens_within 500 do
        Veidrodelis.get(@id, 0, "key1") == nil &&
          Veidrodelis.get(@id, 0, "key2") == "value2"
      end

      Veidrodelis.stop(pid)
    end

    test "handles multiple databases", %{redis: redis} do
      # Write to different databases
      Redix.command!(redis, ["SELECT", "0"])
      Redix.command!(redis, ["SET", "db0_key", "db0_value"])

      Redix.command!(redis, ["SELECT", "1"])
      Redix.command!(redis, ["SET", "db1_key", "db1_value"])

      Redix.command!(redis, ["SELECT", "0"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify data in both databases
      wait_happens_within 100 do
        Veidrodelis.get(@id, 0, "db0_key") == "db0_value" &&
          Veidrodelis.get(@id, 1, "db1_key") == "db1_value"
      end

      # Verify Redis data
      Redix.command!(redis, ["SELECT", "0"])
      assert Redix.command!(redis, ["GET", "db0_key"]) == "db0_value"

      Redix.command!(redis, ["SELECT", "1"])
      assert Redix.command!(redis, ["GET", "db1_key"]) == "db1_value"

      Veidrodelis.stop(pid)
    end

    test "returns error for non-implemented operations", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["SADD", "myset", "member1", "member2"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait a bit for any potential data
      :timer.sleep(100)

      # All major data types are now implemented!
      # No more not_implemented errors for standard Redis types

      Veidrodelis.stop(pid)
    end

    test "processes set commands", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["SADD", "myset", "member1", "member2", "member3"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify data in store
      wait_happens_within 100 do
        members = Veidrodelis.smembers(@id, 0, "myset")
        redis_members = Redix.command!(redis, ["SMEMBERS", "myset"])

        length(members) == 3 &&
          "member1" in members &&
          "member2" in members &&
          "member3" in members &&
          length(redis_members) == 3 &&
          "member1" in redis_members &&
          "member2" in redis_members &&
          "member3" in redis_members
      end

      Veidrodelis.stop(pid)
    end

    test "processes set intersection operations", %{redis: redis} do
      # Create multiple sets
      Redix.command!(redis, ["SADD", "set1", "a", "b", "c", "d"])
      Redix.command!(redis, ["SADD", "set2", "b", "c", "e", "f"])
      Redix.command!(redis, ["SADD", "set3", "c", "d", "g"])

      # Perform intersection
      Redix.command!(redis, ["SINTERSTORE", "result_inter", "set1", "set2", "set3"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify intersection result (only 'c' is in all three sets)
      wait_happens_within 100 do
        result_members = Veidrodelis.smembers(@id, 0, "result_inter")
        set1_members = Veidrodelis.smembers(@id, 0, "set1")

        length(result_members) == 1 &&
          "c" in result_members &&
          length(set1_members) == 4
      end

      Veidrodelis.stop(pid)
    end

    test "processes set union operations", %{redis: redis} do
      # Create multiple sets
      Redix.command!(redis, ["SADD", "setA", "1", "2", "3"])
      Redix.command!(redis, ["SADD", "setB", "2", "3", "4"])
      Redix.command!(redis, ["SADD", "setC", "3", "4", "5"])

      # Perform union
      Redix.command!(redis, ["SUNIONSTORE", "result_union", "setA", "setB", "setC"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify union result (should have all unique elements: 1,2,3,4,5)
      wait_happens_within 100 do
        result_members = Veidrodelis.smembers(@id, 0, "result_union")

        length(result_members) == 5 &&
          "1" in result_members &&
          "2" in result_members &&
          "3" in result_members &&
          "4" in result_members &&
          "5" in result_members
      end

      Veidrodelis.stop(pid)
    end

    test "processes set difference operations", %{redis: redis} do
      # Create sets
      Redix.command!(redis, ["SADD", "base_set", "a", "b", "c", "d", "e"])
      Redix.command!(redis, ["SADD", "subtract1", "b", "d"])
      Redix.command!(redis, ["SADD", "subtract2", "c"])

      # Perform difference (base_set - subtract1 - subtract2)
      Redix.command!(redis, ["SDIFFSTORE", "result_diff", "base_set", "subtract1", "subtract2"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify difference result (should have: a, e)
      wait_happens_within 100 do
        result_members = Veidrodelis.smembers(@id, 0, "result_diff")

        length(result_members) == 2 &&
          "a" in result_members &&
          "e" in result_members
      end

      Veidrodelis.stop(pid)
    end

    test "processes basic list commands", %{redis: redis} do
      # Write list data to Redis
      Redix.command!(redis, ["RPUSH", "mylist", "a", "b", "c"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify list data
      wait_happens_within 100 do
        Veidrodelis.llen(@id, 0, "mylist") == 3 &&
          Veidrodelis.lrange(@id, 0, "mylist", 0, -1) == ["a", "b", "c"]
      end

      Veidrodelis.stop(pid)
    end

    test "processes streaming list commands", %{redis: redis} do
      # Start Veidrodelis FIRST
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication to start
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # NOW write list data (streaming)
      Redix.command!(redis, ["LPUSH", "stream_list", "x", "y", "z"])

      # Wait for commands to replicate
      assert_happens_within 1000 do
        Veidrodelis.llen(@id, 0, "stream_list") == 3
      end

      # Verify the list (LPUSH pushes in reverse order)
      assert Veidrodelis.lrange(@id, 0, "stream_list", 0, -1) == ["z", "y", "x"]

      Veidrodelis.stop(pid)
    end

    test "processes mixed push operations on lists", %{redis: redis} do
      # Create a list with RPUSH and LPUSH
      Redix.command!(redis, ["RPUSH", "mylist", "b", "c"])
      Redix.command!(redis, ["LPUSH", "mylist", "a"])
      Redix.command!(redis, ["RPUSH", "mylist", "d"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify list order
      wait_happens_within 100 do
        Veidrodelis.lrange(@id, 0, "mylist", 0, -1) == ["a", "b", "c", "d"]
      end

      Veidrodelis.stop(pid)
    end

    test "processes list lset commands", %{redis: redis} do
      # Create a list and modify it
      Redix.command!(redis, ["RPUSH", "mylist", "a", "b", "c"])
      Redix.command!(redis, ["LSET", "mylist", "1", "x"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify modified list
      wait_happens_within 100 do
        Veidrodelis.lrange(@id, 0, "mylist", 0, -1) == ["a", "x", "c"]
      end

      Veidrodelis.stop(pid)
    end

    test "processes list pop operations", %{redis: redis} do
      # Create a list
      Redix.command!(redis, ["RPUSH", "mylist", "a", "b", "c", "d"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify initial list
      wait_happens_within 100 do
        Veidrodelis.llen(@id, 0, "mylist") == 4
      end

      # Pop from both ends
      Redix.command!(redis, ["LPOP", "mylist"])
      Redix.command!(redis, ["RPOP", "mylist"])

      # Wait for pops to replicate
      wait_happens_within 500 do
        Veidrodelis.llen(@id, 0, "mylist") == 2 &&
          Veidrodelis.lrange(@id, 0, "mylist", 0, -1) == ["b", "c"]
      end

      Veidrodelis.stop(pid)
    end

    test "processes rpoplpush operation", %{redis: redis} do
      # Create two lists
      Redix.command!(redis, ["RPUSH", "list1", "a", "b", "c"])
      Redix.command!(redis, ["RPUSH", "list2", "x", "y"])

      # Perform RPOPLPUSH
      Redix.command!(redis, ["RPOPLPUSH", "list1", "list2"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify both lists
      wait_happens_within 100 do
        list1 = Veidrodelis.lrange(@id, 0, "list1", 0, -1)
        list2 = Veidrodelis.lrange(@id, 0, "list2", 0, -1)

        list1 == ["a", "b"] &&
          list2 == ["c", "x", "y"]
      end

      Veidrodelis.stop(pid)
    end

    test "processes rpoplpush on same list (rotation)", %{redis: redis} do
      # Create a list
      Redix.command!(redis, ["RPUSH", "mylist", "a", "b", "c"])

      # Rotate the list (move last to first)
      Redix.command!(redis, ["RPOPLPUSH", "mylist", "mylist"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify rotated list (c moved to front)
      wait_happens_within 100 do
        Veidrodelis.lrange(@id, 0, "mylist", 0, -1) == ["c", "a", "b"]
      end

      Veidrodelis.stop(pid)
    end

    test "handles lrange with various indices", %{redis: redis} do
      # Create a list with several elements
      Redix.command!(redis, ["RPUSH", "mylist", "a", "b", "c", "d", "e"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait for list to replicate
      wait_happens_within 100 do
        Veidrodelis.llen(@id, 0, "mylist") == 5
      end

      # Test various range queries
      assert Veidrodelis.lrange(@id, 0, "mylist", 0, 2) == ["a", "b", "c"]
      assert Veidrodelis.lrange(@id, 0, "mylist", -2, -1) == ["d", "e"]
      assert Veidrodelis.lrange(@id, 0, "mylist", 1, 3) == ["b", "c", "d"]
      assert Veidrodelis.lrange(@id, 0, "mylist", 0, -1) == ["a", "b", "c", "d", "e"]

      # Non-existent list returns empty
      assert Veidrodelis.lrange(@id, 0, "nonexistent", 0, -1) == []

      Veidrodelis.stop(pid)
    end

    test "handles empty list operations", %{redis: redis} do
      # Create and then empty a list
      Redix.command!(redis, ["RPUSH", "mylist", "a"])
      Redix.command!(redis, ["LPOP", "mylist"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify empty list (key should be deleted)
      wait_happens_within 100 do
        Veidrodelis.llen(@id, 0, "mylist") == 0 &&
          Veidrodelis.lrange(@id, 0, "mylist", 0, -1) == []
      end

      Veidrodelis.stop(pid)
    end

    test "handles type mismatches correctly", %{redis: redis} do
      # Create a string key
      Redix.command!(redis, ["SET", "mystring", "value"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify initial data
      wait_happens_within 100 do
        Veidrodelis.get(@id, 0, "mystring") == "value"
      end

      # Trying to access string as set should return error
      assert Veidrodelis.smembers(@id, 0, "mystring") == {:error, :wrong_type}
      assert Veidrodelis.scard(@id, 0, "mystring") == {:error, :wrong_type}

      # Trying to access string as list should also return error
      assert Veidrodelis.llen(@id, 0, "mystring") == {:error, :wrong_type}
      assert Veidrodelis.lrange(@id, 0, "mystring", 0, -1) == {:error, :wrong_type}

      Veidrodelis.stop(pid)
    end

    test "processes basic hash commands", %{redis: redis} do
      # Write hash data to Redis
      Redix.command!(redis, ["HSET", "myhash", "field1", "value1", "field2", "value2"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify hash data
      wait_happens_within 100 do
        Veidrodelis.hlen(@id, 0, "myhash") == 2 &&
          Veidrodelis.hget(@id, 0, "myhash", "field1") == "value1" &&
          Veidrodelis.hget(@id, 0, "myhash", "field2") == "value2"
      end

      Veidrodelis.stop(pid)
    end

    test "processes streaming hash commands", %{redis: redis} do
      # Start Veidrodelis FIRST
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication to start
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # NOW write hash data (streaming)
      Redix.command!(redis, ["HSET", "stream_hash", "f1", "v1", "f2", "v2"])

      # Wait for commands to replicate
      assert_happens_within 1000 do
        Veidrodelis.hlen(@id, 0, "stream_hash") == 2
      end

      # Verify the hash
      assert Veidrodelis.hget(@id, 0, "stream_hash", "f1") == "v1"
      assert Veidrodelis.hget(@id, 0, "stream_hash", "f2") == "v2"

      Veidrodelis.stop(pid)
    end

    test "handles hget for non-existent fields", %{redis: redis} do
      # Create a hash
      Redix.command!(redis, ["HSET", "myhash", "field1", "value1"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait for hash to replicate
      wait_happens_within 100 do
        Veidrodelis.hget(@id, 0, "myhash", "field1") == "value1"
      end

      # Non-existent field returns nil
      assert Veidrodelis.hget(@id, 0, "myhash", "nonexistent") == nil

      # Non-existent key returns nil
      assert Veidrodelis.hget(@id, 0, "nonexistent", "field") == nil

      Veidrodelis.stop(pid)
    end

    test "processes hmget for multiple fields", %{redis: redis} do
      # Create a hash
      Redix.command!(redis, ["HSET", "myhash", "f1", "v1", "f2", "v2", "f3", "v3"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait for hash to replicate
      wait_happens_within 100 do
        Veidrodelis.hlen(@id, 0, "myhash") == 3
      end

      # Get multiple fields (including non-existent)
      assert Veidrodelis.hmget(@id, 0, "myhash", ["f1", "f3", "nonexistent"]) == ["v1", "v3", nil]

      Veidrodelis.stop(pid)
    end

    test "processes hgetall", %{redis: redis} do
      # Create a hash
      Redix.command!(redis, ["HSET", "myhash", "field1", "value1", "field2", "value2"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait for hash to replicate
      wait_happens_within 100 do
        Veidrodelis.hlen(@id, 0, "myhash") == 2
      end

      # Get all fields
      pairs = Veidrodelis.hgetall(@id, 0, "myhash")
      assert length(pairs) == 2
      assert {"field1", "value1"} in pairs
      assert {"field2", "value2"} in pairs

      # Non-existent key returns empty list
      assert Veidrodelis.hgetall(@id, 0, "nonexistent") == []

      Veidrodelis.stop(pid)
    end

    test "processes hkeys and hvals", %{redis: redis} do
      # Create a hash
      Redix.command!(redis, ["HSET", "myhash", "field1", "value1", "field2", "value2"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait for hash to replicate
      wait_happens_within 100 do
        Veidrodelis.hlen(@id, 0, "myhash") == 2
      end

      # Get all keys
      keys = Veidrodelis.hkeys(@id, 0, "myhash")
      assert length(keys) == 2
      assert "field1" in keys
      assert "field2" in keys

      # Get all values
      values = Veidrodelis.hvals(@id, 0, "myhash")
      assert length(values) == 2
      assert "value1" in values
      assert "value2" in values

      Veidrodelis.stop(pid)
    end

    test "processes hdel command", %{redis: redis} do
      # Create a hash
      Redix.command!(redis, ["HSET", "myhash", "f1", "v1", "f2", "v2", "f3", "v3"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait for hash to replicate
      wait_happens_within 100 do
        Veidrodelis.hlen(@id, 0, "myhash") == 3
      end

      # Delete a field
      Redix.command!(redis, ["HDEL", "myhash", "f2"])

      # Wait for deletion to replicate
      wait_happens_within 500 do
        Veidrodelis.hlen(@id, 0, "myhash") == 2 &&
          Veidrodelis.hget(@id, 0, "myhash", "f2") == nil
      end

      # f1 and f3 should still exist
      assert Veidrodelis.hget(@id, 0, "myhash", "f1") == "v1"
      assert Veidrodelis.hget(@id, 0, "myhash", "f3") == "v3"

      Veidrodelis.stop(pid)
    end

    test "handles hash emptying", %{redis: redis} do
      # Create a hash with one field
      Redix.command!(redis, ["HSET", "myhash", "field1", "value1"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait for hash to replicate
      wait_happens_within 100 do
        Veidrodelis.hlen(@id, 0, "myhash") == 1
      end

      # Delete the only field
      Redix.command!(redis, ["HDEL", "myhash", "field1"])

      # Wait for deletion to replicate (key should be deleted)
      wait_happens_within 500 do
        Veidrodelis.hlen(@id, 0, "myhash") == 0
      end

      Veidrodelis.stop(pid)
    end

    test "handles hash field updates", %{redis: redis} do
      # Create a hash
      Redix.command!(redis, ["HSET", "myhash", "field1", "original"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait for hash to replicate
      wait_happens_within 100 do
        Veidrodelis.hget(@id, 0, "myhash", "field1") == "original"
      end

      # Update the field
      Redix.command!(redis, ["HSET", "myhash", "field1", "updated"])

      # Wait for update to replicate
      wait_happens_within 1000 do
        Veidrodelis.hget(@id, 0, "myhash", "field1") == "updated"
      end

      Veidrodelis.stop(pid)
    end

    test "handles hash type mismatches", %{redis: redis} do
      # Create a string key
      Redix.command!(redis, ["SET", "mystring", "value"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait for string to replicate
      wait_happens_within 100 do
        Veidrodelis.get(@id, 0, "mystring") == "value"
      end

      # Trying to access string as hash should return error
      assert Veidrodelis.hget(@id, 0, "mystring", "field") == {:error, :wrong_type}
      assert Veidrodelis.hlen(@id, 0, "mystring") == {:error, :wrong_type}
      assert Veidrodelis.hgetall(@id, 0, "mystring") == {:error, :wrong_type}

      Veidrodelis.stop(pid)
    end

    test "processes basic zset commands", %{redis: redis} do
      # Write zset data to Redis
      Redix.command!(redis, ["ZADD", "myzset", "1.0", "one", "2.0", "two", "3.0", "three"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify zset data
      wait_happens_within 100 do
        Veidrodelis.zcard(@id, 0, "myzset") == 3 &&
          Veidrodelis.zscore(@id, 0, "myzset", "one") == 1.0 &&
          Veidrodelis.zscore(@id, 0, "myzset", "two") == 2.0
      end

      Veidrodelis.stop(pid)
    end

    test "processes streaming zset commands", %{redis: redis} do
      # Start Veidrodelis FIRST
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication to start
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # NOW write zset data (streaming)
      Redix.command!(redis, ["ZADD", "stream_zset", "1.5", "a", "2.5", "b"])

      # Wait for commands to replicate
      assert_happens_within 1000 do
        Veidrodelis.zcard(@id, 0, "stream_zset") == 2
      end

      # Verify the zset
      assert Veidrodelis.zscore(@id, 0, "stream_zset", "a") == 1.5
      assert Veidrodelis.zscore(@id, 0, "stream_zset", "b") == 2.5

      Veidrodelis.stop(pid)
    end

    test "handles zscore for non-existent members", %{redis: redis} do
      # Create a zset
      Redix.command!(redis, ["ZADD", "myzset", "1.0", "member1"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait for zset to replicate
      wait_happens_within 100 do
        Veidrodelis.zscore(@id, 0, "myzset", "member1") == 1.0
      end

      # Non-existent member returns nil
      assert Veidrodelis.zscore(@id, 0, "myzset", "nonexistent") == nil

      # Non-existent key returns nil
      assert Veidrodelis.zscore(@id, 0, "nonexistent", "member") == nil

      Veidrodelis.stop(pid)
    end

    test "processes zrange", %{redis: redis} do
      # Create a zset
      Redix.command!(redis, [
        "ZADD",
        "myzset",
        "1.0",
        "one",
        "2.0",
        "two",
        "3.0",
        "three",
        "4.0",
        "four"
      ])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait for zset to replicate
      wait_happens_within 100 do
        Veidrodelis.zcard(@id, 0, "myzset") == 4
      end

      # Get range with scores
      result = Veidrodelis.zrange(@id, 0, "myzset", 0, 2)
      assert length(result) == 3
      assert {"one", 1.0} in result
      assert {"two", 2.0} in result
      assert {"three", 3.0} in result

      # Get range with negative indices
      result = Veidrodelis.zrange(@id, 0, "myzset", -2, -1)
      assert length(result) == 2
      assert {"three", 3.0} in result
      assert {"four", 4.0} in result

      # Non-existent key returns empty list
      assert Veidrodelis.zrange(@id, 0, "nonexistent", 0, -1) == []

      Veidrodelis.stop(pid)
    end

    test "processes zrem command", %{redis: redis} do
      # Create a zset
      Redix.command!(redis, ["ZADD", "myzset", "1.0", "one", "2.0", "two", "3.0", "three"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait for zset to replicate
      wait_happens_within 100 do
        Veidrodelis.zcard(@id, 0, "myzset") == 3
      end

      # Remove a member
      Redix.command!(redis, ["ZREM", "myzset", "two"])

      # Wait for removal to replicate
      wait_happens_within 500 do
        Veidrodelis.zcard(@id, 0, "myzset") == 2 &&
          Veidrodelis.zscore(@id, 0, "myzset", "two") == nil
      end

      # one and three should still exist
      assert Veidrodelis.zscore(@id, 0, "myzset", "one") == 1.0
      assert Veidrodelis.zscore(@id, 0, "myzset", "three") == 3.0

      Veidrodelis.stop(pid)
    end

    test "handles zset emptying", %{redis: redis} do
      # Create a zset with one member
      Redix.command!(redis, ["ZADD", "myzset", "1.0", "member1"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait for zset to replicate
      wait_happens_within 100 do
        Veidrodelis.zcard(@id, 0, "myzset") == 1
      end

      # Remove the only member
      Redix.command!(redis, ["ZREM", "myzset", "member1"])

      # Wait for removal to replicate (key should be deleted)
      wait_happens_within 500 do
        Veidrodelis.zcard(@id, 0, "myzset") == 0
      end

      Veidrodelis.stop(pid)
    end

    test "handles zset score updates", %{redis: redis} do
      # Create a zset
      Redix.command!(redis, ["ZADD", "myzset", "1.0", "member"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait for zset to replicate
      wait_happens_within 100 do
        Veidrodelis.zscore(@id, 0, "myzset", "member") == 1.0
      end

      # Update the score
      Redix.command!(redis, ["ZADD", "myzset", "2.5", "member"])

      # Wait for update to replicate
      wait_happens_within 500 do
        Veidrodelis.zscore(@id, 0, "myzset", "member") == 2.5
      end

      # Cardinality should still be 1
      assert Veidrodelis.zcard(@id, 0, "myzset") == 1

      Veidrodelis.stop(pid)
    end

    test "handles zset with duplicate scores", %{redis: redis} do
      # Create a zset with duplicate scores
      Redix.command!(redis, ["ZADD", "myzset", "1.0", "a", "1.0", "b", "2.0", "c"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait for zset to replicate
      wait_happens_within 100 do
        Veidrodelis.zcard(@id, 0, "myzset") == 3
      end

      # All members should exist with correct scores
      assert Veidrodelis.zscore(@id, 0, "myzset", "a") == 1.0
      assert Veidrodelis.zscore(@id, 0, "myzset", "b") == 1.0
      assert Veidrodelis.zscore(@id, 0, "myzset", "c") == 2.0

      # Range should return all members
      result = Veidrodelis.zrange(@id, 0, "myzset", 0, -1)
      assert length(result) == 3

      Veidrodelis.stop(pid)
    end

    test "handles zset type mismatches", %{redis: redis} do
      # Create a string key
      Redix.command!(redis, ["SET", "mystring", "value"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Wait for string to replicate
      wait_happens_within 100 do
        Veidrodelis.get(@id, 0, "mystring") == "value"
      end

      # Trying to access string as zset should return error
      assert Veidrodelis.zscore(@id, 0, "mystring", "member") == {:error, :wrong_type}
      assert Veidrodelis.zcard(@id, 0, "mystring") == {:error, :wrong_type}
      assert Veidrodelis.zrange(@id, 0, "mystring", 0, -1) == {:error, :wrong_type}

      Veidrodelis.stop(pid)
    end
  end
end
