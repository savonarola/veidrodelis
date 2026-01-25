defmodule VeidrodelisTest do
  use ExUnit.Case, async: false

  require Logger

  use CommandMatchers

  @redis_host "localhost"
  @redis_port 16378
  @id "vdr_id"

  @veidrodelis_base_opts [
    id: @id,
    host: @redis_host,
    port: @redis_port
  ]

  def veidrodelis_opts(opts \\ []) do
    @veidrodelis_base_opts ++ opts
  end

  setup do
    # Ensure Redis is running
    {:ok, redis} = Redix.start_link(host: @redis_host, port: @redis_port)

    # Flush all databases before each test
    Redix.command!(redis, ["FLUSHALL"])

    {:ok, redis: redis}
  end

  describe "string commands" do
    test "processes string commands from RDB", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["SET", "key1", "value1"])
      Redix.command!(redis, ["SET", "key2", "value2"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify data in store
      assert_within 100 do
        assert {:ok, "value1"} == Veidrodelis.get(@id, 0, "key1")
        assert {:ok, "value2"} == Veidrodelis.get(@id, 0, "key2")
        assert "value1" == Redix.command!(redis, ["GET", "key1"])
        assert "value2" == Redix.command!(redis, ["GET", "key2"])
      end

      Veidrodelis.stop(pid)
    end

    test "processes streaming string commands", %{redis: redis} do
      # Start Veidrodelis FIRST (before writing data)
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication to start
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # NOW write data to Redis (these will come via streaming, not RDB)
      Redix.command!(redis, ["SET", "stream_key", "stream_value"])

      # Wait for commands to replicate
      assert_within 1000 do
        assert {:ok, "stream_value"} == Veidrodelis.get(@id, 0, "stream_key")
      end

      Veidrodelis.stop(pid)
    end

    test "handles del commands", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["SET", "key1", "value1"])
      Redix.command!(redis, ["SET", "key2", "value2"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify initial data
      assert_within 100 do
        assert {:ok, "value1"} == Veidrodelis.get(@id, 0, "key1")
        assert {:ok, "value2"} == Veidrodelis.get(@id, 0, "key2")
      end

      # Delete one key
      Redix.command!(redis, ["DEL", "key1"])

      # Wait for deletion to replicate
      assert_within 500 do
        assert {:ok, nil} == Veidrodelis.get(@id, 0, "key1")
        assert {:ok, "value2"} == Veidrodelis.get(@id, 0, "key2")
      end

      Veidrodelis.stop(pid)
    end

    test "handles type changes correctly", %{redis: redis} do
      # Start Veidrodelis first so we can test streaming commands
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Create a string value
      Redix.command!(redis, ["SET", "typekey", "string_value"])

      # Wait for it to replicate
      assert_within 500 do
        assert {:ok, "string_value"} == Veidrodelis.get(@id, 0, "typekey")
      end

      # Change to a list
      Redix.command!(redis, ["DEL", "typekey"])

      assert_within 500 do
        assert {:ok, nil} == Veidrodelis.get(@id, 0, "typekey")
      end

      Redix.command!(redis, ["RPUSH", "typekey", "list_item1", "list_item2"])

      # Wait for it to replicate
      assert_within 500 do
        assert {:ok,
                [
                  "list_item1",
                  "list_item2"
                ]} == Veidrodelis.lrange(@id, 0, "typekey", 0, -1)
      end

      # Change to a set
      Redix.command!(redis, ["DEL", "typekey"])

      assert_within 500 do
        assert {:ok, 0} == Veidrodelis.llen(@id, 0, "typekey")
      end

      Redix.command!(redis, ["SADD", "typekey", "set_member1", "set_member2"])

      # Wait for it to replicate
      assert_within 500 do
        assert {:ok, 2} == Veidrodelis.scard(@id, 0, "typekey")
      end

      Veidrodelis.stop(pid)
    end
  end

  describe "set commands" do
    test "processes set commands from RDB", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["SADD", "myset", "member1", "member2", "member3"])

      # Start Veidrodelis instance
      instance_id = :"test_sets_#{:erlang.unique_integer([:positive])}"

      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts(id: instance_id))

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify data in store
      assert_within 100 do
        {:ok, members} = Veidrodelis.smembers(@id, 0, "myset")
        redis_members = Redix.command!(redis, ["SMEMBERS", "myset"])

        assert 3 == length(members)
        assert "member1" in members
        assert "member2" in members
        assert "member3" in members
        assert 3 == length(redis_members)
        assert "member1" in redis_members
        assert "member2" in redis_members
        assert "member3" in redis_members
      end

      Veidrodelis.stop(pid)
    end

    test "processes streaming set commands", %{redis: redis} do
      # Start Veidrodelis FIRST (before writing data)
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication to start
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # NOW write data to Redis (streaming)
      Redix.command!(redis, ["SADD", "stream_set", "s1", "s2"])

      # Wait for commands to replicate
      assert_within 1000 do
        assert {:ok, 2} == Veidrodelis.scard(@id, 0, "stream_set")
      end

      {:ok, members} = Veidrodelis.smembers(@id, 0, "stream_set")
      assert "s1" in members
      assert "s2" in members

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
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify intersection result (only 'c' is in all three sets)
      assert_within 100 do
        {:ok, result_members} = Veidrodelis.smembers(@id, 0, "result_inter")
        {:ok, set1_members} = Veidrodelis.smembers(@id, 0, "set1")

        assert 1 == length(result_members)
        assert "c" in result_members
        assert 4 == length(set1_members)
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
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify union result (should have all unique elements: 1,2,3,4,5)
      assert_within 100 do
        {:ok, result_members} = Veidrodelis.smembers(@id, 0, "result_union")

        assert 5 == length(result_members)
        assert "1" in result_members
        assert "2" in result_members
        assert "3" in result_members
        assert "4" in result_members
        assert "5" in result_members
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
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify difference result (should have: a, e)
      assert_within 100 do
        {:ok, result_members} = Veidrodelis.smembers(@id, 0, "result_diff")

        assert 2 == length(result_members)
        assert "a" in result_members
        assert "e" in result_members
      end

      Veidrodelis.stop(pid)
    end

    test "handles set type mismatches", %{redis: redis} do
      # Create a string key
      Redix.command!(redis, ["SET", "mystring", "value"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify initial data
      assert_within 100 do
        assert {:ok, "value"} == Veidrodelis.get(@id, 0, "mystring")
      end

      # Trying to access string as set should return error
      assert {:error, "WRONGTYPE: Operation against a key holding the wrong kind of value"} ==
               Veidrodelis.smembers(@id, 0, "mystring")

      assert {:error, "WRONGTYPE: Operation against a key holding the wrong kind of value"} ==
               Veidrodelis.scard(@id, 0, "mystring")

      Veidrodelis.stop(pid)
    end
  end

  describe "list commands" do
    test "processes basic list commands from RDB", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["RPUSH", "mylist", "item1", "item2", "item3"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify data in store
      assert_within 100 do
        {:ok, elements} = Veidrodelis.lrange(@id, 0, "mylist", 0, -1)
        redis_elements = Redix.command!(redis, ["LRANGE", "mylist", "0", "-1"])

        assert 3 == length(elements)
        assert ["item1", "item2", "item3"] == elements
        assert ["item1", "item2", "item3"] == redis_elements
      end

      Veidrodelis.stop(pid)
    end

    test "processes streaming list commands", %{redis: redis} do
      # Start Veidrodelis FIRST
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication to start
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # NOW write list data (streaming)
      Redix.command!(redis, ["LPUSH", "stream_list", "x", "y", "z"])

      # Wait for commands to replicate
      assert_within 1000 do
        assert {:ok, 3} == Veidrodelis.llen(@id, 0, "stream_list")
      end

      # Verify the list (LPUSH pushes in reverse order)
      assert {:ok, ["z", "y", "x"]} == Veidrodelis.lrange(@id, 0, "stream_list", 0, -1)

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
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify list order
      assert_within 100 do
        assert {:ok, ["a", "b", "c", "d"]} == Veidrodelis.lrange(@id, 0, "mylist", 0, -1)
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
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify modified list
      assert_within 100 do
        assert {:ok, ["a", "x", "c"]} == Veidrodelis.lrange(@id, 0, "mylist", 0, -1)
      end

      Veidrodelis.stop(pid)
    end

    test "processes list pop operations", %{redis: redis} do
      # Create a list
      Redix.command!(redis, ["RPUSH", "mylist", "a", "b", "c", "d"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify initial list
      assert_within 100 do
        assert {:ok, 4} == Veidrodelis.llen(@id, 0, "mylist")
      end

      # Pop from both ends
      Redix.command!(redis, ["LPOP", "mylist"])
      Redix.command!(redis, ["RPOP", "mylist"])

      # Wait for pops to replicate
      assert_within 500 do
        assert {:ok, 2} == Veidrodelis.llen(@id, 0, "mylist")
        assert {:ok, ["b", "c"]} == Veidrodelis.lrange(@id, 0, "mylist", 0, -1)
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
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify both lists
      assert_within 100 do
        assert {:ok, ["a", "b"]} == Veidrodelis.lrange(@id, 0, "list1", 0, -1)
        assert {:ok, ["c", "x", "y"]} == Veidrodelis.lrange(@id, 0, "list2", 0, -1)
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
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify rotated list (c moved to front)
      assert_within 100 do
        assert {:ok, ["c", "a", "b"]} == Veidrodelis.lrange(@id, 0, "mylist", 0, -1)
      end

      Veidrodelis.stop(pid)
    end

    test "handles lrange with various indices", %{redis: redis} do
      # Create a list with several elements
      Redix.command!(redis, ["RPUSH", "mylist", "a", "b", "c", "d", "e"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Wait for list to replicate
      assert_within 100 do
        assert {:ok, 5} == Veidrodelis.llen(@id, 0, "mylist")
      end

      # Test various range queries
      assert {:ok, ["a", "b", "c"]} == Veidrodelis.lrange(@id, 0, "mylist", 0, 2)
      assert {:ok, ["d", "e"]} == Veidrodelis.lrange(@id, 0, "mylist", -2, -1)
      assert {:ok, ["b", "c", "d"]} == Veidrodelis.lrange(@id, 0, "mylist", 1, 3)
      assert {:ok, ["a", "b", "c", "d", "e"]} == Veidrodelis.lrange(@id, 0, "mylist", 0, -1)

      # Non-existent list returns empty
      assert {:ok, []} == Veidrodelis.lrange(@id, 0, "nonexistent", 0, -1)

      Veidrodelis.stop(pid)
    end

    test "handles empty list operations", %{redis: redis} do
      # Create and then empty a list
      Redix.command!(redis, ["RPUSH", "mylist", "a"])
      Redix.command!(redis, ["LPOP", "mylist"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify empty list (key should be deleted)
      assert_within 100 do
        assert {:ok, 0} == Veidrodelis.llen(@id, 0, "mylist")
        assert {:ok, []} == Veidrodelis.lrange(@id, 0, "mylist", 0, -1)
      end

      Veidrodelis.stop(pid)
    end

    test "handles list type mismatches", %{redis: redis} do
      # Create a string key
      Redix.command!(redis, ["SET", "mystring", "value"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify initial data
      assert_within 100 do
        assert {:ok, "value"} == Veidrodelis.get(@id, 0, "mystring")
      end

      # Trying to access string as list should return error
      assert {:error, "WRONGTYPE: Operation against a key holding the wrong kind of value"} ==
               Veidrodelis.llen(@id, 0, "mystring")

      assert {:error, "WRONGTYPE: Operation against a key holding the wrong kind of value"} ==
               Veidrodelis.lrange(@id, 0, "mystring", 0, -1)

      Veidrodelis.stop(pid)
    end
  end

  describe "hash commands" do
    test "processes basic hash commands from RDB", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["HSET", "myhash", "field1", "value1", "field2", "value2"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify data in store
      assert_within 100 do
        assert {:ok, "value1"} == Veidrodelis.hget(@id, 0, "myhash", "field1")
        assert {:ok, "value2"} == Veidrodelis.hget(@id, 0, "myhash", "field2")
        assert "value1" == Redix.command!(redis, ["HGET", "myhash", "field1"])
        assert "value2" == Redix.command!(redis, ["HGET", "myhash", "field2"])
      end

      Veidrodelis.stop(pid)
    end

    test "processes streaming hash commands", %{redis: redis} do
      # Start Veidrodelis FIRST
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication to start
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # NOW write hash data (streaming)
      Redix.command!(redis, ["HSET", "stream_hash", "f1", "v1", "f2", "v2"])

      # Wait for commands to replicate
      assert_within 1000 do
        assert {:ok, 2} == Veidrodelis.hlen(@id, 0, "stream_hash")
      end

      # Verify the hash
      assert {:ok, "v1"} == Veidrodelis.hget(@id, 0, "stream_hash", "f1")
      assert {:ok, "v2"} == Veidrodelis.hget(@id, 0, "stream_hash", "f2")

      Veidrodelis.stop(pid)
    end

    test "handles hget for non-existent fields", %{redis: redis} do
      # Create a hash
      Redix.command!(redis, ["HSET", "myhash", "field1", "value1"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Wait for hash to replicate
      assert_within 100 do
        assert {:ok, "value1"} == Veidrodelis.hget(@id, 0, "myhash", "field1")
      end

      # Non-existent field returns nil
      assert {:ok, nil} == Veidrodelis.hget(@id, 0, "myhash", "nonexistent")

      # Non-existent key returns nil
      assert {:ok, nil} == Veidrodelis.hget(@id, 0, "nonexistent", "field")

      Veidrodelis.stop(pid)
    end

    test "processes hmget for multiple fields", %{redis: redis} do
      # Create a hash
      Redix.command!(redis, ["HSET", "myhash", "f1", "v1", "f2", "v2", "f3", "v3"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Wait for hash to replicate
      assert_within 100 do
        assert {:ok, 3} == Veidrodelis.hlen(@id, 0, "myhash")
      end

      # Get multiple fields (including non-existent)
      assert {:ok, ["v1", "v3", nil]} ==
               Veidrodelis.hmget(@id, 0, "myhash", ["f1", "f3", "nonexistent"])

      Veidrodelis.stop(pid)
    end

    test "processes hgetall", %{redis: redis} do
      # Create a hash
      Redix.command!(redis, ["HSET", "myhash", "field1", "value1", "field2", "value2"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Wait for hash to replicate
      assert_within 100 do
        assert {:ok, 2} == Veidrodelis.hlen(@id, 0, "myhash")
      end

      # Get all fields
      {:ok, pairs} = Veidrodelis.hgetall(@id, 0, "myhash")
      assert length(pairs) == 2
      assert {"field1", "value1"} in pairs
      assert {"field2", "value2"} in pairs

      # Non-existent key returns empty list
      assert {:ok, []} == Veidrodelis.hgetall(@id, 0, "nonexistent")

      Veidrodelis.stop(pid)
    end

    test "processes hkeys and hvals", %{redis: redis} do
      # Create a hash
      Redix.command!(redis, ["HSET", "myhash", "field1", "value1", "field2", "value2"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Wait for hash to replicate
      assert_within 100 do
        assert {:ok, 2} == Veidrodelis.hlen(@id, 0, "myhash")
      end

      # Get all keys
      {:ok, keys} = Veidrodelis.hkeys(@id, 0, "myhash")
      assert length(keys) == 2
      assert "field1" in keys
      assert "field2" in keys

      # Get all values
      {:ok, values} = Veidrodelis.hvals(@id, 0, "myhash")
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
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Wait for hash to replicate
      assert_within 100 do
        assert {:ok, 3} == Veidrodelis.hlen(@id, 0, "myhash")
      end

      # Delete a field
      Redix.command!(redis, ["HDEL", "myhash", "f2"])

      # Wait for deletion to replicate
      assert_within 500 do
        assert {:ok, 2} == Veidrodelis.hlen(@id, 0, "myhash")
        assert {:ok, nil} == Veidrodelis.hget(@id, 0, "myhash", "f2")
      end

      # f1 and f3 should still exist
      assert {:ok, "v1"} == Veidrodelis.hget(@id, 0, "myhash", "f1")
      assert {:ok, "v3"} == Veidrodelis.hget(@id, 0, "myhash", "f3")

      Veidrodelis.stop(pid)
    end

    test "handles hash emptying", %{redis: redis} do
      # Create a hash with one field
      Redix.command!(redis, ["HSET", "myhash", "field1", "value1"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Wait for hash to replicate
      assert_within 100 do
        assert {:ok, 1} == Veidrodelis.hlen(@id, 0, "myhash")
      end

      # Delete the only field
      Redix.command!(redis, ["HDEL", "myhash", "field1"])

      # Wait for deletion to replicate (key should be deleted)
      assert_within 500 do
        assert {:ok, 0} == Veidrodelis.hlen(@id, 0, "myhash")
      end

      Veidrodelis.stop(pid)
    end

    test "handles hash field updates", %{redis: redis} do
      # Create a hash
      Redix.command!(redis, ["HSET", "myhash", "field1", "original"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Wait for hash to replicate
      assert_within 100 do
        assert {:ok, "original"} == Veidrodelis.hget(@id, 0, "myhash", "field1")
      end

      # Update the field
      Redix.command!(redis, ["HSET", "myhash", "field1", "updated"])

      # Wait for update to replicate
      assert_within 1000 do
        assert {:ok, "updated"} == Veidrodelis.hget(@id, 0, "myhash", "field1")
      end

      Veidrodelis.stop(pid)
    end

    test "handles hash type mismatches", %{redis: redis} do
      # Create a string key
      Redix.command!(redis, ["SET", "mystring", "value"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Wait for string to replicate
      assert_within 100 do
        assert {:ok, "value"} == Veidrodelis.get(@id, 0, "mystring")
      end

      # Trying to access string as hash should return error
      assert {:error, "WRONGTYPE: Operation against a key holding the wrong kind of value"} ==
               Veidrodelis.hget(@id, 0, "mystring", "field")

      assert {:error, "WRONGTYPE: Operation against a key holding the wrong kind of value"} ==
               Veidrodelis.hlen(@id, 0, "mystring")

      assert {:error, "WRONGTYPE: Operation against a key holding the wrong kind of value"} ==
               Veidrodelis.hgetall(@id, 0, "mystring")

      Veidrodelis.stop(pid)
    end
  end

  describe "zset commands" do
    test "processes basic zset commands from RDB", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, [
        "ZADD",
        "myzset",
        "1.0",
        "member1",
        "2.5",
        "member2",
        "3.0",
        "member3"
      ])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify data in store (zrange returns tuples with scores)
      assert_within 1000 do
        assert {:ok,
                [
                  {"member1", 1.0},
                  {"member2", 2.5},
                  {"member3", 3.0}
                ]} == Veidrodelis.zrange(@id, 0, "myzset", 0, -1)
      end

      # Verify data in Redis hasn't changed
      redis_members = Redix.command!(redis, ["ZRANGE", "myzset", "0", "-1", "WITHSCORES"])
      assert ["member1", "1", "member2", "2.5", "member3", "3"] == redis_members

      Veidrodelis.stop(pid)
    end

    test "processes streaming zset commands", %{redis: redis} do
      # Start Veidrodelis FIRST
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication to start
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # NOW write zset data (streaming)
      Redix.command!(redis, ["ZADD", "stream_zset", "1.5", "a", "2.5", "b"])

      # Wait for commands to replicate
      assert_within 1000 do
        assert {:ok, 2} == Veidrodelis.zcard(@id, 0, "stream_zset")
      end

      # Verify the zset
      assert {:ok, 1.5} == Veidrodelis.zscore(@id, 0, "stream_zset", "a")
      assert {:ok, 2.5} == Veidrodelis.zscore(@id, 0, "stream_zset", "b")

      Veidrodelis.stop(pid)
    end

    test "handles zscore for non-existent members", %{redis: redis} do
      # Create a zset
      Redix.command!(redis, ["ZADD", "myzset", "1.0", "member1"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Wait for zset to replicate
      assert_within 100 do
        assert {:ok, 1.0} == Veidrodelis.zscore(@id, 0, "myzset", "member1")
      end

      # Non-existent member returns nil
      assert {:ok, nil} == Veidrodelis.zscore(@id, 0, "myzset", "nonexistent")

      # Non-existent key returns nil
      assert {:ok, nil} == Veidrodelis.zscore(@id, 0, "nonexistent", "member")

      Veidrodelis.stop(pid)
    end

    test "processes zrange with various indices", %{redis: redis} do
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
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Wait for zset to replicate
      assert_within 100 do
        assert {:ok, 4} == Veidrodelis.zcard(@id, 0, "myzset")
      end

      # Get range with scores
      {:ok, result} = Veidrodelis.zrange(@id, 0, "myzset", 0, 2)
      assert length(result) == 3
      assert {"one", 1.0} in result
      assert {"two", 2.0} in result
      assert {"three", 3.0} in result

      # Get range with negative indices
      {:ok, result} = Veidrodelis.zrange(@id, 0, "myzset", -2, -1)
      assert length(result) == 2
      assert {"three", 3.0} in result
      assert {"four", 4.0} in result

      # Non-existent key returns empty list
      assert {:ok, []} == Veidrodelis.zrange(@id, 0, "nonexistent", 0, -1)

      Veidrodelis.stop(pid)
    end

    test "processes zrem command", %{redis: redis} do
      # Create a zset
      Redix.command!(redis, ["ZADD", "myzset", "1.0", "one", "2.0", "two", "3.0", "three"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Wait for zset to replicate
      assert_within 100 do
        assert {:ok, 3} == Veidrodelis.zcard(@id, 0, "myzset")
      end

      # Remove a member
      Redix.command!(redis, ["ZREM", "myzset", "two"])

      # Wait for removal to replicate
      assert_within 500 do
        assert {:ok, 2} == Veidrodelis.zcard(@id, 0, "myzset")
        assert {:ok, nil} == Veidrodelis.zscore(@id, 0, "myzset", "two")
      end

      # one and three should still exist
      assert {:ok, 1.0} == Veidrodelis.zscore(@id, 0, "myzset", "one")
      assert {:ok, 3.0} == Veidrodelis.zscore(@id, 0, "myzset", "three")

      Veidrodelis.stop(pid)
    end

    test "handles zset emptying", %{redis: redis} do
      # Create a zset with one member
      Redix.command!(redis, ["ZADD", "myzset", "1.0", "member1"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Wait for zset to replicate
      assert_within 100 do
        assert {:ok, 1} == Veidrodelis.zcard(@id, 0, "myzset")
      end

      # Remove the only member
      Redix.command!(redis, ["ZREM", "myzset", "member1"])

      # Wait for removal to replicate (key should be deleted)
      assert_within 500 do
        assert {:ok, 0} == Veidrodelis.zcard(@id, 0, "myzset")
      end

      Veidrodelis.stop(pid)
    end

    test "handles zset score updates", %{redis: redis} do
      # Create a zset
      Redix.command!(redis, ["ZADD", "myzset", "1.0", "member"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Wait for zset to replicate
      assert_within 100 do
        assert {:ok, 1.0} == Veidrodelis.zscore(@id, 0, "myzset", "member")
      end

      # Update the score
      Redix.command!(redis, ["ZADD", "myzset", "2.5", "member"])

      # Wait for update to replicate
      assert_within 500 do
        assert {:ok, 2.5} == Veidrodelis.zscore(@id, 0, "myzset", "member")
      end

      # Cardinality should still be 1
      assert {:ok, 1} == Veidrodelis.zcard(@id, 0, "myzset")

      Veidrodelis.stop(pid)
    end

    test "handles zset with duplicate scores", %{redis: redis} do
      # Create a zset with duplicate scores
      Redix.command!(redis, ["ZADD", "myzset", "1.0", "a", "1.0", "b", "2.0", "c"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Wait for zset to replicate
      assert_within 100 do
        assert {:ok, 3} == Veidrodelis.zcard(@id, 0, "myzset")
      end

      # All members should exist with correct scores
      assert {:ok, 1.0} == Veidrodelis.zscore(@id, 0, "myzset", "a")
      assert {:ok, 1.0} == Veidrodelis.zscore(@id, 0, "myzset", "b")
      assert {:ok, 2.0} == Veidrodelis.zscore(@id, 0, "myzset", "c")

      # Range should return all members
      {:ok, result} = Veidrodelis.zrange(@id, 0, "myzset", 0, -1)
      assert length(result) == 3

      Veidrodelis.stop(pid)
    end

    test "handles zset type mismatches", %{redis: redis} do
      # Create a string key
      Redix.command!(redis, ["SET", "mystring", "value"])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Wait for string to replicate
      assert_within 100 do
        assert {:ok, "value"} == Veidrodelis.get(@id, 0, "mystring")
      end

      # Trying to access string as zset should return error
      assert {:error, "WRONGTYPE: Operation against a key holding the wrong kind of value"} ==
               Veidrodelis.zscore(@id, 0, "mystring", "member")

      assert {:error, "WRONGTYPE: Operation against a key holding the wrong kind of value"} ==
               Veidrodelis.zcard(@id, 0, "mystring")

      assert {:error, "WRONGTYPE: Operation against a key holding the wrong kind of value"} ==
               Veidrodelis.zrange(@id, 0, "mystring", 0, -1)

      Veidrodelis.stop(pid)
    end

    test "processes zset union with weights", %{redis: redis} do
      # Create sorted sets
      Redix.command!(redis, ["ZADD", "zset1", "1", "member1", "2", "member2", "3", "member3"])
      Redix.command!(redis, ["ZADD", "zset2", "2", "member1", "3", "member2", "4", "member4"])

      # Union with weights: zset1 * 2 + zset2 * 3
      Redix.command!(redis, [
        "ZUNIONSTORE",
        "result_weighted_union",
        "2",
        "zset1",
        "zset2",
        "WEIGHTS",
        "2",
        "3"
      ])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify weighted union results
      # member1: 1*2 + 2*3 = 8
      # member2: 2*2 + 3*3 = 13
      # member3: 3*2 + 0*3 = 6
      # member4: 0*2 + 4*3 = 12
      assert_within 1000 do
        assert {:ok,
                [
                  {"member3", 6.0},
                  {"member1", 8.0},
                  {"member4", 12.0},
                  {"member2", 13.0}
                ]} == Veidrodelis.zrange(@id, 0, "result_weighted_union", 0, -1)
      end

      Veidrodelis.stop(pid)
    end

    test "processes zset intersection with MIN aggregation", %{redis: redis} do
      # Create sorted sets
      Redix.command!(redis, ["ZADD", "scores1", "10", "alice", "20", "bob", "30", "charlie"])
      Redix.command!(redis, ["ZADD", "scores2", "15", "alice", "25", "bob", "5", "david"])

      # Intersection with MIN aggregation (only members in both sets, take minimum score)
      Redix.command!(redis, [
        "ZINTERSTORE",
        "result_inter_min",
        "2",
        "scores1",
        "scores2",
        "AGGREGATE",
        "MIN"
      ])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify intersection with MIN (only alice and bob exist in both)
      # alice: min(10, 15) = 10
      # bob: min(20, 25) = 20
      assert_within 100 do
        assert {:ok,
                [
                  {"alice", 10.0},
                  {"bob", 20.0}
                ]} == Veidrodelis.zrange(@id, 0, "result_inter_min", 0, -1)
      end

      Veidrodelis.stop(pid)
    end

    test "processes zset intersection with MAX aggregation", %{redis: redis} do
      # Create sorted sets
      Redix.command!(redis, ["ZADD", "priority1", "5", "task1", "8", "task2"])
      Redix.command!(redis, ["ZADD", "priority2", "7", "task1", "3", "task2"])

      # Intersection with MAX aggregation
      Redix.command!(redis, [
        "ZINTERSTORE",
        "result_inter_max",
        "2",
        "priority1",
        "priority2",
        "AGGREGATE",
        "MAX"
      ])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify intersection with MAX
      # task1: max(5, 7) = 7
      # task2: max(8, 3) = 8
      assert_within 100 do
        assert {:ok,
                [
                  {"task1", 7.0},
                  {"task2", 8.0}
                ]} == Veidrodelis.zrange(@id, 0, "result_inter_max", 0, -1)
      end

      Veidrodelis.stop(pid)
    end

    test "processes zset union with weights and SUM aggregation", %{redis: redis} do
      # Create sorted sets with different semantic meanings
      Redix.command!(redis, ["ZADD", "rating_quality", "8.5", "product1", "9.0", "product2"])
      Redix.command!(redis, ["ZADD", "rating_price", "7.0", "product1", "6.5", "product2"])
      Redix.command!(redis, ["ZADD", "rating_delivery", "9.5", "product1", "8.0", "product3"])

      # Union with custom weights (quality=50%, price=30%, delivery=20%)
      Redix.command!(redis, [
        "ZUNIONSTORE",
        "combined_rating",
        "3",
        "rating_quality",
        "rating_price",
        "rating_delivery",
        "WEIGHTS",
        "0.5",
        "0.3",
        "0.2",
        "AGGREGATE",
        "SUM"
      ])

      # Start Veidrodelis instance
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts())

      # Wait for replication
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify weighted sum results
      # product1: 8.5*0.5 + 7.0*0.3 + 9.5*0.2 = 4.25 + 2.1 + 1.9 = 8.25
      # product2: 9.0*0.5 + 6.5*0.3 + 0*0.2 = 4.5 + 1.95 + 0 = 6.45
      # product3: 0*0.5 + 0*0.3 + 8.0*0.2 = 0 + 0 + 1.6 = 1.6
      assert_within 100 do
        assert {:ok,
                [
                  {"product3", 1.6},
                  {"product2", 6.45},
                  {"product1", 8.25}
                ]} == Veidrodelis.zrange(@id, 0, "combined_rating", 0, -1)
      end

      Veidrodelis.stop(pid)
    end
  end

  describe "multiple databases" do
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
      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(pid)
      end

      # Verify data in both databases
      assert_within 100 do
        assert {:ok, "db0_value"} == Veidrodelis.get(@id, 0, "db0_key")
        assert {:ok, "db1_value"} == Veidrodelis.get(@id, 1, "db1_key")
      end

      # Verify Redis data
      Redix.command!(redis, ["SELECT", "0"])
      assert "db0_value" == Redix.command!(redis, ["GET", "db0_key"])

      Redix.command!(redis, ["SELECT", "1"])
      assert "db1_value" == Redix.command!(redis, ["GET", "db1_key"])

      Veidrodelis.stop(pid)
    end
  end

  describe "tx/3" do
    test "smoke test for Lua execution", %{redis: redis} do
      id = :"test_tx_#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        Veidrodelis.start_link(
          id: id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(id)
      end

      # Test basic script execution (returns proper type now)
      assert {:ok, 42} = Veidrodelis.read_tx(id, 0, "return 42")

      # Test ts.get access to replicated data
      Redix.command!(redis, ["SET", "lua_key", "lua_value"])

      assert_within 500 do
        assert {:ok, "lua_value"} == Veidrodelis.get(id, 0, "lua_key")
      end

      script = "return ts.get('lua_key')"
      assert {:ok, "lua_value"} = Veidrodelis.read_tx(id, 0, script)
    end
  end

  describe "read_tx/3 with command list" do
    test "executes multiple read commands atomically", %{redis: redis} do
      id = :"test_read_tx_list_#{:erlang.unique_integer([:positive])}"

      # Set up test data
      Redix.command!(redis, ["SET", "key1", "value1"])
      Redix.command!(redis, ["SET", "key2", "value2"])
      Redix.command!(redis, ["HSET", "hash1", "field1", "hvalue1", "field2", "hvalue2"])

      {:ok, _pid} =
        Veidrodelis.start_link(
          id: id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(id)
      end

      # Wait for data to replicate
      assert_within 500 do
        assert {:ok, "value1"} == Veidrodelis.get(id, 0, "key1")
      end

      # Execute multiple read commands atomically
      assert {:ok, [val1, val2, hval1]} =
               Veidrodelis.read_tx(id, 0, [
                 {:get, "key1"},
                 {:get, "key2"},
                 {:hget, "hash1", "field1"}
               ])

      assert val1 == {:ok, "value1"}
      assert val2 == {:ok, "value2"}
      assert hval1 == {:ok, "hvalue1"}
    end

    test "handles mixed data types in single transaction", %{redis: redis} do
      id = :"test_read_tx_mixed_#{:erlang.unique_integer([:positive])}"

      # Set up diverse test data
      Redix.command!(redis, ["SET", "str_key", "string_value"])
      Redix.command!(redis, ["RPUSH", "list_key", "item1", "item2", "item3"])
      Redix.command!(redis, ["SADD", "set_key", "member1", "member2"])
      Redix.command!(redis, ["HSET", "hash_key", "f1", "v1", "f2", "v2"])
      Redix.command!(redis, ["ZADD", "zset_key", "1.0", "a", "2.0", "b", "3.0", "c"])

      {:ok, _pid} =
        Veidrodelis.start_link(
          id: id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(id)
      end

      # Wait for data to replicate
      assert_within 500 do
        assert {:ok, "string_value"} == Veidrodelis.get(id, 0, "str_key")
      end

      # Execute mixed read commands
      assert {:ok, [str_val, list_len, set_card, hash_val, zset_card]} =
               Veidrodelis.read_tx(id, 0, [
                 {:get, "str_key"},
                 {:llen, "list_key"},
                 {:scard, "set_key"},
                 {:hget, "hash_key", "f1"},
                 {:zcard, "zset_key"}
               ])

      assert str_val == {:ok, "string_value"}
      assert list_len == {:ok, 3}
      assert set_card == {:ok, 2}
      assert hash_val == {:ok, "v1"}
      assert zset_card == {:ok, 3}
    end

    test "returns nil for non-existent keys", %{redis: redis} do
      id = :"test_read_tx_nil_#{:erlang.unique_integer([:positive])}"

      Redix.command!(redis, ["SET", "existing_key", "exists"])

      {:ok, _pid} =
        Veidrodelis.start_link(
          id: id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(id)
      end

      assert_within 500 do
        assert {:ok, "exists"} == Veidrodelis.get(id, 0, "existing_key")
      end

      # Mix of existing and non-existing keys
      assert {:ok, [val1, val2, val3]} =
               Veidrodelis.read_tx(id, 0, [
                 {:get, "existing_key"},
                 {:get, "nonexistent_key"},
                 {:hget, "nonexistent_hash", "field"}
               ])

      assert val1 == {:ok, "exists"}
      assert val2 == {:ok, nil}
      assert val3 == {:ok, nil}
    end

    test "rejects write commands with readonly_violation error", %{redis: redis} do
      id = :"test_read_tx_readonly_#{:erlang.unique_integer([:positive])}"

      Redix.command!(redis, ["SET", "some_key", "some_value"])

      {:ok, _pid} =
        Veidrodelis.start_link(
          id: id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(id)
      end

      # Attempt to include a write command - returns readonly_violation for that command
      assert {:ok, [get_result, set_result]} =
               Veidrodelis.read_tx(id, 0, [
                 {:get, "some_key"},
                 {:set, "new_key", "new_value"}
               ])

      assert get_result == {:ok, "some_value"}
      assert set_result == {:error, "Unknown read command"}
    end

    test "handles empty command list", %{redis: _redis} do
      id = :"test_read_tx_empty_#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        Veidrodelis.start_link(
          id: id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(id)
      end

      # Empty command list should return empty results
      assert {:ok, []} = Veidrodelis.read_tx(id, 0, [])
    end

    test "works with hmget for multiple hash fields", %{redis: redis} do
      id = :"test_read_tx_hmget_#{:erlang.unique_integer([:positive])}"

      Redix.command!(redis, ["HSET", "user:1", "name", "Alice", "age", "30", "city", "NYC"])

      {:ok, _pid} =
        Veidrodelis.start_link(
          id: id,
          host: @redis_host,
          port: @redis_port
        )

      assert_within 2000 do
        assert :streaming == Veidrodelis.get_replication_state(id)
      end

      assert_within 500 do
        assert {:ok, "Alice"} == Veidrodelis.hget(id, 0, "user:1", "name")
      end

      # Use hmget in read_tx
      assert {:ok, [values]} =
               Veidrodelis.read_tx(id, 0, [
                 {:hmget, "user:1", ["name", "age", "nonexistent"]}
               ])

      assert values == {:ok, ["Alice", "30", nil]}
    end
  end
end
