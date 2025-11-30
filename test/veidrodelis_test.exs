defmodule VeidrodelisTest do
  use ExUnit.Case, async: false

  use CommandMatchers

  @redis_host "localhost"
  @redis_port 16378

  # Test decoder that transforms data in non-trivial ways
  defmodule TestDecoder do
    @behaviour Veidrodelis

    # String decoding: prefix key with "str:"
    @impl true
    def decode_string_key(key), do: "str:#{key}"

    # String value: wrap in tuple with metadata
    @impl true
    def decode_string_value(key, value), do: {:string_value, key, value}

    # Set decoding: prefix key with "set:"
    @impl true
    def decode_set_key(key), do: "set:#{key}"

    # Set entry: wrap in tuple
    @impl true
    def decode_set_entry(_set_key, entry), do: {:set_entry, entry}

    # List decoding: prefix key with "list:"
    @impl true
    def decode_list_key(key), do: "list:#{key}"

    # List entry: wrap with index metadata
    @impl true
    def decode_list_entry(_list_key, entry), do: {:list_entry, entry}

    # Hash decoding: prefix key with "hash:"
    @impl true
    def decode_hash_key(key), do: "hash:#{key}"

    # Hash field key: wrap in tuple
    @impl true
    def decode_hash_hkey(_hash_key, hkey), do: {:hash_field, hkey}

    # Hash entry: wrap with metadata
    @impl true
    def decode_hash_entry(_hash_key, hkey, value), do: {:hash_value, hkey, value}

    # Zset decoding: prefix key with "zset:"
    @impl true
    def decode_zset_key(key), do: "zset:#{key}"

    # Zset entry: wrap in tuple
    @impl true
    def decode_zset_entry(_zset_key, entry), do: {:zset_entry, entry}
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

  describe "Veidrodelis with custom decoder" do
    test "processes string commands with decoder", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["SET", "key1", "value1"])
      Redix.command!(redis, ["SET", "key2", "value2"])

      # Start Veidrodelis instance with custom decoder
      instance_id = :"test_strings_#{:erlang.unique_integer([:positive])}"

      {:ok, vdr} =
        Veidrodelis.start_link(
          id: instance_id,
          decoder: TestDecoder,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      # Give it a moment to process commands
      Process.sleep(100)

      # Get stores
      string_store = Veidrodelis.strings(instance_id)

      # Verify decoded data in store
      assert Vdr.StringStore.get_decoded(string_store, 0, "str:key1") ==
               {:string_value, "str:key1", "value1"}

      assert Vdr.StringStore.get_decoded(string_store, 0, "str:key2") ==
               {:string_value, "str:key2", "value2"}

      # Verify data in Redis hasn't changed
      assert Redix.command!(redis, ["GET", "key1"]) == "value1"
      assert Redix.command!(redis, ["GET", "key2"]) == "value2"

      Veidrodelis.stop(vdr)
    end

    test "processes set commands with decoder", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["SADD", "myset", "member1", "member2", "member3"])

      # Start Veidrodelis instance with custom decoder
      instance_id = :"test_sets_#{:erlang.unique_integer([:positive])}"

      {:ok, vdr} =
        Veidrodelis.start_link(
          id: instance_id,
          decoder: TestDecoder,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      Process.sleep(100)

      # Get stores
      set_store = Veidrodelis.sets(instance_id)

      # Verify decoded data in store
      members = Vdr.SetStore.smembers(set_store, 0, "set:myset")
      assert length(members) == 3
      assert {:set_entry, "member1"} in members
      assert {:set_entry, "member2"} in members
      assert {:set_entry, "member3"} in members

      # Verify data in Redis hasn't changed
      redis_members = Redix.command!(redis, ["SMEMBERS", "myset"])
      assert length(redis_members) == 3
      assert "member1" in redis_members
      assert "member2" in redis_members
      assert "member3" in redis_members

      Veidrodelis.stop(vdr)
    end

    test "processes list commands with decoder", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["RPUSH", "mylist", "item1", "item2", "item3"])

      # Start Veidrodelis instance with custom decoder
      instance_id = :"test_lists_#{:erlang.unique_integer([:positive])}"

      {:ok, vdr} =
        Veidrodelis.start_link(
          id: instance_id,
          decoder: TestDecoder,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      Process.sleep(100)

      # Get stores
      list_store = Veidrodelis.lists(instance_id)

      # Verify decoded data in store
      items = Vdr.ListStore.get_range(list_store, 0, "list:mylist", 0, -1)
      assert items == [{:list_entry, "item1"}, {:list_entry, "item2"}, {:list_entry, "item3"}]

      # Verify data in Redis hasn't changed
      redis_items = Redix.command!(redis, ["LRANGE", "mylist", "0", "-1"])
      assert redis_items == ["item1", "item2", "item3"]

      Veidrodelis.stop(vdr)
    end

    test "processes hash commands with decoder", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["HSET", "myhash", "field1", "value1", "field2", "value2"])

      # Start Veidrodelis instance with custom decoder
      instance_id = :"test_hashes_#{:erlang.unique_integer([:positive])}"

      {:ok, vdr} =
        Veidrodelis.start_link(
          id: instance_id,
          decoder: TestDecoder,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      Process.sleep(100)

      # Get stores
      hash_store = Veidrodelis.hashes(instance_id)

      # Verify decoded data in store (pass raw field, it will be decoded)
      value1 = Vdr.HashStore.hget(hash_store, 0, "hash:myhash", "field1")
      value2 = Vdr.HashStore.hget(hash_store, 0, "hash:myhash", "field2")

      assert value1 == {:hash_value, {:hash_field, "field1"}, "value1"}
      assert value2 == {:hash_value, {:hash_field, "field2"}, "value2"}

      # Verify data in Redis hasn't changed
      assert Redix.command!(redis, ["HGET", "myhash", "field1"]) == "value1"
      assert Redix.command!(redis, ["HGET", "myhash", "field2"]) == "value2"

      Veidrodelis.stop(vdr)
    end

    test "processes zset commands with decoder", %{redis: redis} do
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

      # Start Veidrodelis instance with custom decoder
      instance_id = :"test_zsets_#{:erlang.unique_integer([:positive])}"

      {:ok, vdr} =
        Veidrodelis.start_link(
          id: instance_id,
          decoder: TestDecoder,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      Process.sleep(100)

      # Get stores
      zset_store = Veidrodelis.zsets(instance_id)

      # Verify decoded data in store (zrange returns tuples with scores)
      members_with_scores = Vdr.ZsetStore.zrange(zset_store, 0, "zset:myzset", 0, -1)

      assert members_with_scores == [
               {{:zset_entry, "member1"}, 1.0},
               {{:zset_entry, "member2"}, 2.5},
               {{:zset_entry, "member3"}, 3.0}
             ]

      # Verify data in Redis hasn't changed
      redis_members = Redix.command!(redis, ["ZRANGE", "myzset", "0", "-1", "WITHSCORES"])
      assert redis_members == ["member1", "1", "member2", "2.5", "member3", "3"]

      Veidrodelis.stop(vdr)
    end

    test "processes streaming commands with decoder", %{redis: redis} do
      # Start Veidrodelis FIRST (before writing data)
      instance_id = :"test_streaming_#{:erlang.unique_integer([:positive])}"

      {:ok, vdr} =
        Veidrodelis.start_link(
          id: instance_id,
          decoder: TestDecoder,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for replication to start
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      # NOW write data to Redis (these will come via streaming, not RDB)
      Redix.command!(redis, ["SET", "stream_key", "stream_value"])
      Redix.command!(redis, ["SADD", "stream_set", "s1", "s2"])
      Redix.command!(redis, ["RPUSH", "stream_list", "l1", "l2"])

      # Wait for commands to replicate
      assert_happens_within 1000 do
        string_store = Veidrodelis.strings(instance_id)
        set_store = Veidrodelis.sets(instance_id)
        list_store = Veidrodelis.lists(instance_id)

        Vdr.StringStore.get_decoded(string_store, 0, "str:stream_key") != nil &&
          Vdr.SetStore.scard(set_store, 0, "set:stream_set") == 2 &&
          length(Vdr.ListStore.get_range(list_store, 0, "list:stream_list", 0, -1)) == 2
      end

      # Verify the data
      string_store = Veidrodelis.strings(instance_id)
      set_store = Veidrodelis.sets(instance_id)
      list_store = Veidrodelis.lists(instance_id)

      assert Vdr.StringStore.get_decoded(string_store, 0, "str:stream_key") ==
               {:string_value, "str:stream_key", "stream_value"}

      members = Vdr.SetStore.smembers(set_store, 0, "set:stream_set")
      assert {:set_entry, "s1"} in members
      assert {:set_entry, "s2"} in members

      items = Vdr.ListStore.get_range(list_store, 0, "list:stream_list", 0, -1)
      assert items == [{:list_entry, "l1"}, {:list_entry, "l2"}]

      Veidrodelis.stop(vdr)
    end

    test "handles type changes correctly", %{redis: redis} do
      # Write a string first
      Redix.command!(redis, ["SET", "changeable", "initial_string"])

      # Start Veidrodelis instance
      instance_id = :"test_type_change_#{:erlang.unique_integer([:positive])}"

      {:ok, vdr} =
        Veidrodelis.start_link(
          id: instance_id,
          decoder: TestDecoder,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      Process.sleep(100)

      # Verify string is there
      string_store = Veidrodelis.strings(instance_id)

      assert Vdr.StringStore.get_decoded(string_store, 0, "str:changeable") ==
               {:string_value, "str:changeable", "initial_string"}

      # Change type to list
      Redix.command!(redis, ["DEL", "changeable"])
      Redix.command!(redis, ["RPUSH", "changeable", "list_item"])

      # Wait for change to replicate
      assert_happens_within 1000 do
        list_store = Veidrodelis.lists(instance_id)
        length(Vdr.ListStore.get_range(list_store, 0, "list:changeable", 0, -1)) == 1
      end

      # Verify string is gone and list is there
      assert Vdr.StringStore.get_decoded(string_store, 0, "str:changeable") == nil

      list_store = Veidrodelis.lists(instance_id)
      items = Vdr.ListStore.get_range(list_store, 0, "list:changeable", 0, -1)
      assert items == [{:list_entry, "list_item"}]

      Veidrodelis.stop(vdr)
    end

    test "handles multiple databases", %{redis: redis} do
      # Write to different databases
      Redix.command!(redis, ["SELECT", "0"])
      Redix.command!(redis, ["SET", "db0_key", "db0_value"])

      Redix.command!(redis, ["SELECT", "1"])
      Redix.command!(redis, ["SET", "db1_key", "db1_value"])

      Redix.command!(redis, ["SELECT", "0"])

      # Start Veidrodelis instance
      instance_id = :"test_multi_db_#{:erlang.unique_integer([:positive])}"

      {:ok, vdr} =
        Veidrodelis.start_link(
          id: instance_id,
          decoder: TestDecoder,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      Process.sleep(100)

      # Verify data in both databases
      string_store = Veidrodelis.strings(instance_id)

      assert Vdr.StringStore.get_decoded(string_store, 0, "str:db0_key") ==
               {:string_value, "str:db0_key", "db0_value"}

      assert Vdr.StringStore.get_decoded(string_store, 1, "str:db1_key") ==
               {:string_value, "str:db1_key", "db1_value"}

      # Verify Redis data
      Redix.command!(redis, ["SELECT", "0"])
      assert Redix.command!(redis, ["GET", "db0_key"]) == "db0_value"

      Redix.command!(redis, ["SELECT", "1"])
      assert Redix.command!(redis, ["GET", "db1_key"]) == "db1_value"

      Veidrodelis.stop(vdr)
    end

    test "processes set intersection operations", %{redis: redis} do
      # Create multiple sets
      Redix.command!(redis, ["SADD", "set1", "a", "b", "c", "d"])
      Redix.command!(redis, ["SADD", "set2", "b", "c", "e", "f"])
      Redix.command!(redis, ["SADD", "set3", "c", "d", "g"])

      # Perform intersection
      Redix.command!(redis, ["SINTERSTORE", "result_inter", "set1", "set2", "set3"])

      # Start Veidrodelis instance
      instance_id = :"test_set_inter_#{:erlang.unique_integer([:positive])}"

      {:ok, vdr} =
        Veidrodelis.start_link(
          id: instance_id,
          decoder: TestDecoder,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      Process.sleep(100)

      # Get stores
      set_store = Veidrodelis.sets(instance_id)

      # Verify intersection result (only 'c' is in all three sets)
      result_members = Vdr.SetStore.smembers(set_store, 0, "set:result_inter")
      assert length(result_members) == 1
      assert {:set_entry, "c"} in result_members

      # Verify original sets
      set1_members = Vdr.SetStore.smembers(set_store, 0, "set:set1")
      assert length(set1_members) == 4

      Veidrodelis.stop(vdr)
    end

    test "processes set union operations", %{redis: redis} do
      # Create multiple sets
      Redix.command!(redis, ["SADD", "setA", "1", "2", "3"])
      Redix.command!(redis, ["SADD", "setB", "2", "3", "4"])
      Redix.command!(redis, ["SADD", "setC", "3", "4", "5"])

      # Perform union
      Redix.command!(redis, ["SUNIONSTORE", "result_union", "setA", "setB", "setC"])

      # Start Veidrodelis instance
      instance_id = :"test_set_union_#{:erlang.unique_integer([:positive])}"

      {:ok, vdr} =
        Veidrodelis.start_link(
          id: instance_id,
          decoder: TestDecoder,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      Process.sleep(100)

      # Get stores
      set_store = Veidrodelis.sets(instance_id)

      # Verify union result (should have all unique elements: 1,2,3,4,5)
      result_members = Vdr.SetStore.smembers(set_store, 0, "set:result_union")
      assert length(result_members) == 5
      assert {:set_entry, "1"} in result_members
      assert {:set_entry, "2"} in result_members
      assert {:set_entry, "3"} in result_members
      assert {:set_entry, "4"} in result_members
      assert {:set_entry, "5"} in result_members

      Veidrodelis.stop(vdr)
    end

    test "processes set difference operations", %{redis: redis} do
      # Create sets
      Redix.command!(redis, ["SADD", "base_set", "a", "b", "c", "d", "e"])
      Redix.command!(redis, ["SADD", "subtract1", "b", "d"])
      Redix.command!(redis, ["SADD", "subtract2", "c"])

      # Perform difference (base_set - subtract1 - subtract2)
      Redix.command!(redis, ["SDIFFSTORE", "result_diff", "base_set", "subtract1", "subtract2"])

      # Start Veidrodelis instance
      instance_id = :"test_set_diff_#{:erlang.unique_integer([:positive])}"

      {:ok, vdr} =
        Veidrodelis.start_link(
          id: instance_id,
          decoder: TestDecoder,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      Process.sleep(100)

      # Get stores
      set_store = Veidrodelis.sets(instance_id)

      # Verify difference result (should have: a, e)
      result_members = Vdr.SetStore.smembers(set_store, 0, "set:result_diff")
      assert length(result_members) == 2
      assert {:set_entry, "a"} in result_members
      assert {:set_entry, "e"} in result_members

      Veidrodelis.stop(vdr)
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
      instance_id = :"test_zset_weighted_union_#{:erlang.unique_integer([:positive])}"

      {:ok, vdr} =
        Veidrodelis.start_link(
          id: instance_id,
          decoder: TestDecoder,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      Process.sleep(100)

      # Get stores
      zset_store = Veidrodelis.zsets(instance_id)

      # Verify weighted union results
      # member1: 1*2 + 2*3 = 8
      # member2: 2*2 + 3*3 = 13
      # member3: 3*2 + 0*3 = 6
      # member4: 0*2 + 4*3 = 12
      result = Vdr.ZsetStore.zrange(zset_store, 0, "zset:result_weighted_union", 0, -1)

      assert result == [
               {{:zset_entry, "member3"}, 6.0},
               {{:zset_entry, "member1"}, 8.0},
               {{:zset_entry, "member4"}, 12.0},
               {{:zset_entry, "member2"}, 13.0}
             ]

      Veidrodelis.stop(vdr)
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
      instance_id = :"test_zset_inter_min_#{:erlang.unique_integer([:positive])}"

      {:ok, vdr} =
        Veidrodelis.start_link(
          id: instance_id,
          decoder: TestDecoder,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      Process.sleep(100)

      # Get stores
      zset_store = Veidrodelis.zsets(instance_id)

      # Verify intersection with MIN (only alice and bob exist in both)
      # alice: min(10, 15) = 10
      # bob: min(20, 25) = 20
      result = Vdr.ZsetStore.zrange(zset_store, 0, "zset:result_inter_min", 0, -1)

      assert result == [
               {{:zset_entry, "alice"}, 10.0},
               {{:zset_entry, "bob"}, 20.0}
             ]

      Veidrodelis.stop(vdr)
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
      instance_id = :"test_zset_inter_max_#{:erlang.unique_integer([:positive])}"

      {:ok, vdr} =
        Veidrodelis.start_link(
          id: instance_id,
          decoder: TestDecoder,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      Process.sleep(100)

      # Get stores
      zset_store = Veidrodelis.zsets(instance_id)

      # Verify intersection with MAX
      # task1: max(5, 7) = 7
      # task2: max(8, 3) = 8
      result = Vdr.ZsetStore.zrange(zset_store, 0, "zset:result_inter_max", 0, -1)

      assert result == [
               {{:zset_entry, "task1"}, 7.0},
               {{:zset_entry, "task2"}, 8.0}
             ]

      Veidrodelis.stop(vdr)
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
      instance_id = :"test_zset_weighted_sum_#{:erlang.unique_integer([:positive])}"

      {:ok, vdr} =
        Veidrodelis.start_link(
          id: instance_id,
          decoder: TestDecoder,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      Process.sleep(100)

      # Get stores
      zset_store = Veidrodelis.zsets(instance_id)

      # Verify weighted sum results
      # product1: 8.5*0.5 + 7.0*0.3 + 9.5*0.2 = 4.25 + 2.1 + 1.9 = 8.25
      # product2: 9.0*0.5 + 6.5*0.3 + 0*0.2 = 4.5 + 1.95 + 0 = 6.45
      # product3: 0*0.5 + 0*0.3 + 8.0*0.2 = 0 + 0 + 1.6 = 1.6
      result = Vdr.ZsetStore.zrange(zset_store, 0, "zset:combined_rating", 0, -1)

      assert result == [
               {{:zset_entry, "product3"}, 1.6},
               {{:zset_entry, "product2"}, 6.45},
               {{:zset_entry, "product1"}, 8.25}
             ]

      Veidrodelis.stop(vdr)
    end

    test "on_destroy is called on termination", %{redis: _redis} do
      # Start Veidrodelis instance
      instance_id = :"test_destroy_#{:erlang.unique_integer([:positive])}"

      {:ok, vdr} =
        Veidrodelis.start_link(
          id: instance_id,
          decoder: TestDecoder,
          host: @redis_host,
          port: @redis_port
        )

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(vdr) == :streaming
      end

      # Verify stores are registered
      assert Veidrodelis.strings(instance_id) != nil

      # Stop Veidrodelis (should call on_destroy)
      Veidrodelis.stop(vdr)

      # Give it a moment to cleanup
      Process.sleep(100)

      # Verify stores are deregistered
      assert_raise ArgumentError, fn ->
        Veidrodelis.strings(instance_id)
      end
    end
  end
end
