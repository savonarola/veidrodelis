defmodule VeidrodelisTest do
  use ExUnit.Case, async: false

  require Logger

  use CommandMatchers

  @redis_host "localhost"
  @redis_port 16378

  # Test decoder that transforms data in non-trivial ways
  defmodule TestDecoder do
    @behaviour Veidrodelis

    # Key decoding: prefix all keys with "key:" regardless of type
    # This decoder works identically for all Redis data types
    @impl true
    def decode_key(key), do: "key:#{key}"

    # String value: wrap in tuple with metadata
    @impl true
    def decode_string_value(key, value), do: {:string_value, key, value}

    # Set entry: wrap in tuple
    @impl true
    def decode_set_entry(_set_key, entry), do: {:set_entry, entry}

    # Hash field key: wrap in tuple
    @impl true
    def decode_hash_hkey(_hash_key, hkey), do: {:hash_field, hkey}

    # Hash entry: wrap with metadata
    @impl true
    def decode_hash_entry(_hash_key, hkey, value), do: {:hash_value, hkey, value}

    # Zset entry: wrap in tuple
    @impl true
    def decode_zset_entry(_zset_key, entry), do: {:zset_entry, entry}

    # List entry: wrap in tuple
    @impl true
    def decode_list_entry(_list_key, entry), do: {:list_entry, entry}
  end

  @veidrodelis_base_opts [
    decoder: TestDecoder,
    host: @redis_host,
    port: @redis_port
  ]

  def veidrodelis_opts(opts) do
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

  describe "Veidrodelis with custom decoder" do
    test "processes string commands with decoder", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["SET", "key1", "value1"])
      Redix.command!(redis, ["SET", "key2", "value2"])

      # Start Veidrodelis instance with custom decoder
      instance_id = :"test_strings_#{:erlang.unique_integer([:positive])}"

      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts(id: instance_id))

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify decoded data in store
      wait_happens_within 100 do
        Veidrodelis.get_decoded(pid, 0, "key:key1") ==
          {:string_value, "key:key1", "value1"} &&
          Veidrodelis.get_decoded(pid, 0, "key:key2") ==
          {:string_value, "key:key2", "value2"} &&
          Redix.command!(redis, ["GET", "key1"]) == "value1" &&
          Redix.command!(redis, ["GET", "key2"]) == "value2"
      end

      Veidrodelis.stop(pid)
    end

    test "processes set commands with decoder", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["SADD", "myset", "member1", "member2", "member3"])

      # Start Veidrodelis instance with custom decoder
      instance_id = :"test_sets_#{:erlang.unique_integer([:positive])}"

      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts(id: instance_id))

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify decoded data in store
      wait_happens_within 100 do
        members = Veidrodelis.smembers(pid, 0, "key:myset")
        redis_members = Redix.command!(redis, ["SMEMBERS", "myset"])
        length(members) == 3 &&
          {:set_entry, "member1"} in members &&
          {:set_entry, "member2"} in members &&
          {:set_entry, "member3"} in members &&
          length(redis_members) == 3 &&
          "member1" in redis_members &&
          "member2" in redis_members &&
          "member3" in redis_members
      end

      Veidrodelis.stop(pid)
    end

    test "processes list commands with decoder", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["RPUSH", "mylist", "item1", "item2", "item3"])

      # Start Veidrodelis instance with custom decoder
      instance_id = :"test_lists_#{:erlang.unique_integer([:positive])}"

      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts(id: instance_id))

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify decoded data in store
      wait_happens_within 100 do
        elements = Veidrodelis.lrange(pid, 0, "key:mylist", 0, -1)
        redis_elements = Redix.command!(redis, ["LRANGE", "mylist", "0", "-1"])
        length(elements) == 3 &&
          elements == [
            {:list_entry, "item1"},
            {:list_entry, "item2"},
            {:list_entry, "item3"}
          ] &&
          redis_elements == ["item1", "item2", "item3"]
      end

      Veidrodelis.stop(pid)
    end

    test "processes hash commands with decoder", %{redis: redis} do
      # Write data to Redis
      Redix.command!(redis, ["HSET", "myhash", "field1", "value1", "field2", "value2"])

      # Start Veidrodelis instance with custom decoder
      instance_id = :"test_hashes_#{:erlang.unique_integer([:positive])}"

      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts(id: instance_id))

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify decoded data in store (pass decoded field key)
      wait_happens_within 100 do
        value1 = Veidrodelis.hget(pid, 0, "key:myhash", {:hash_field, "field1"})
        value2 = Veidrodelis.hget(pid, 0, "key:myhash", {:hash_field, "field2"})
        value1 == {:hash_value, {:hash_field, "field1"}, "value1"} &&
          value2 == {:hash_value, {:hash_field, "field2"}, "value2"} &&
          Redix.command!(redis, ["HGET", "myhash", "field1"]) == "value1" &&
          Redix.command!(redis, ["HGET", "myhash", "field2"]) == "value2"
      end

      Veidrodelis.stop(pid)
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

      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts(id: instance_id))

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify decoded data in store (zrange returns tuples with scores)
      assert_happens_within 1000 do
        members_with_scores = Veidrodelis.zrange(pid, 0, "key:myzset", 0, -1)

        members_with_scores == [
          {{:zset_entry, "member1"}, 1.0},
          {{:zset_entry, "member2"}, 2.5},
          {{:zset_entry, "member3"}, 3.0}
        ]
      end

      # Verify data in Redis hasn't changed
      redis_members = Redix.command!(redis, ["ZRANGE", "myzset", "0", "-1", "WITHSCORES"])
      assert redis_members == ["member1", "1", "member2", "2.5", "member3", "3"]

      Veidrodelis.stop(pid)
    end

    test "processes streaming commands with decoder", %{redis: redis} do
      # Start Veidrodelis FIRST (before writing data)
      instance_id = :"test_streaming_#{:erlang.unique_integer([:positive])}"

      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts(id: instance_id))

      # Wait for replication to start
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # NOW write data to Redis (these will come via streaming, not RDB)
      Redix.command!(redis, ["SET", "stream_key", "stream_value"])
      Redix.command!(redis, ["SADD", "stream_set", "s1", "s2"])

      # Wait for commands to replicate
      assert_happens_within 1000 do
        Veidrodelis.get_decoded(pid, 0, "key:stream_key") != nil &&
          Veidrodelis.scard(pid, 0, "key:stream_set") == 2
      end

      # Verify the data
      assert Veidrodelis.get_decoded(pid, 0, "key:stream_key") ==
               {:string_value, "key:stream_key", "stream_value"}

      members = Veidrodelis.smembers(pid, 0, "key:stream_set")
      assert {:set_entry, "s1"} in members
      assert {:set_entry, "s2"} in members

      Veidrodelis.stop(pid)
    end

    test "handles type changes correctly", %{redis: redis} do
      # Start Veidrodelis first so we can test streaming commands
      instance_id = :"test_type_changes_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts(id: instance_id))

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Create a string value
      Redix.command!(redis, ["SET", "typekey", "string_value"])

      # Wait for it to replicate
      wait_happens_within 500 do
        Veidrodelis.get_decoded(pid, 0, "key:typekey") ==
          {:string_value, "key:typekey", "string_value"}
      end

      # Change to a list
      Redix.command!(redis, ["DEL", "typekey"])
      Redix.command!(redis, ["RPUSH", "typekey", "list_item1", "list_item2"])

      # Wait for it to replicate
      wait_happens_within 500 do
        Veidrodelis.get_decoded(pid, 0, "key:typekey") == nil &&
          Veidrodelis.lrange(pid, 0, "key:typekey", 0, -1) == [
            {:list_entry, "list_item1"},
            {:list_entry, "list_item2"}
          ]
      end

      # Change to a set
      Redix.command!(redis, ["DEL", "typekey"])
      Redix.command!(redis, ["SADD", "typekey", "set_member1", "set_member2"])

      # Wait for it to replicate
      wait_happens_within 500 do
        Veidrodelis.llen(pid, 0, "key:typekey") == 0 &&
          Veidrodelis.scard(pid, 0, "key:typekey") == 2
      end

      # Verify Redis has the current data
      assert Redix.command!(redis, ["TYPE", "typekey"]) == "set"
      redis_members = Redix.command!(redis, ["SMEMBERS", "typekey"])
      assert "set_member1" in redis_members
      assert "set_member2" in redis_members

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
      instance_id = :"test_multi_db_#{:erlang.unique_integer([:positive])}"

      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts(id: instance_id))

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify data in both databases
      wait_happens_within 100 do
        Veidrodelis.get_decoded(pid, 0, "key:db0_key") ==
          {:string_value, "key:db0_key", "db0_value"} &&
          Veidrodelis.get_decoded(pid, 1, "key:db1_key") ==
          {:string_value, "key:db1_key", "db1_value"}
      end

      # Verify Redis data
      Redix.command!(redis, ["SELECT", "0"])
      assert Redix.command!(redis, ["GET", "db0_key"]) == "db0_value"

      Redix.command!(redis, ["SELECT", "1"])
      assert Redix.command!(redis, ["GET", "db1_key"]) == "db1_value"

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
      instance_id = :"test_set_inter_#{:erlang.unique_integer([:positive])}"

      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts(id: instance_id))

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify intersection result (only 'c' is in all three sets)
      wait_happens_within 100 do
        result_members = Veidrodelis.smembers(pid, 0, "key:result_inter")
        set1_members = Veidrodelis.smembers(pid, 0, "key:set1")
        length(result_members) == 1 &&
          {:set_entry, "c"} in result_members &&
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
      instance_id = :"test_set_union_#{:erlang.unique_integer([:positive])}"

      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts(id: instance_id))

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify union result (should have all unique elements: 1,2,3,4,5)
      wait_happens_within 100 do
        result_members = Veidrodelis.smembers(pid, 0, "key:result_union")
        length(result_members) == 5 &&
          {:set_entry, "1"} in result_members &&
          {:set_entry, "2"} in result_members &&
          {:set_entry, "3"} in result_members &&
          {:set_entry, "4"} in result_members &&
          {:set_entry, "5"} in result_members
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
      instance_id = :"test_set_diff_#{:erlang.unique_integer([:positive])}"

      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts(id: instance_id))

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify difference result (should have: a, e)
      wait_happens_within 100 do
        result_members = Veidrodelis.smembers(pid, 0, "key:result_diff")
        length(result_members) == 2 &&
          {:set_entry, "a"} in result_members &&
          {:set_entry, "e"} in result_members
      end

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
      instance_id = :"test_zset_weighted_union_#{:erlang.unique_integer([:positive])}"

      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts(id: instance_id))

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify weighted union results
      # member1: 1*2 + 2*3 = 8
      # member2: 2*2 + 3*3 = 13
      # member3: 3*2 + 0*3 = 6
      # member4: 0*2 + 4*3 = 12
      assert_happens_within 1000 do
        result = Veidrodelis.zrange(pid, 0, "key:result_weighted_union", 0, -1)
        result == [
          {{:zset_entry, "member3"}, 6.0},
          {{:zset_entry, "member1"}, 8.0},
          {{:zset_entry, "member4"}, 12.0},
          {{:zset_entry, "member2"}, 13.0}
        ]
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
      instance_id = :"test_zset_inter_min_#{:erlang.unique_integer([:positive])}"

      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts(id: instance_id))

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify intersection with MIN (only alice and bob exist in both)
      # alice: min(10, 15) = 10
      # bob: min(20, 25) = 20
      wait_happens_within 100 do
        result = Veidrodelis.zrange(pid, 0, "key:result_inter_min", 0, -1)
        result == [
          {{:zset_entry, "alice"}, 10.0},
          {{:zset_entry, "bob"}, 20.0}
        ]
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
      instance_id = :"test_zset_inter_max_#{:erlang.unique_integer([:positive])}"

      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts(id: instance_id))

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify intersection with MAX
      # task1: max(5, 7) = 7
      # task2: max(8, 3) = 8
      wait_happens_within 100 do
        result = Veidrodelis.zrange(pid, 0, "key:result_inter_max", 0, -1)
        result == [
          {{:zset_entry, "task1"}, 7.0},
          {{:zset_entry, "task2"}, 8.0}
        ]
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
      instance_id = :"test_zset_weighted_sum_#{:erlang.unique_integer([:positive])}"

      {:ok, pid} = Veidrodelis.start_link(veidrodelis_opts(id: instance_id))

      # Wait for replication
      assert_happens_within 2000 do
        Veidrodelis.get_replication_state(pid) == :streaming
      end

      # Verify weighted sum results
      # product1: 8.5*0.5 + 7.0*0.3 + 9.5*0.2 = 4.25 + 2.1 + 1.9 = 8.25
      # product2: 9.0*0.5 + 6.5*0.3 + 0*0.2 = 4.5 + 1.95 + 0 = 6.45
      # product3: 0*0.5 + 0*0.3 + 8.0*0.2 = 0 + 0 + 1.6 = 1.6
      wait_happens_within 100 do
        result = Veidrodelis.zrange(pid, 0, "key:combined_rating", 0, -1)
        result == [
          {{:zset_entry, "product3"}, 1.6},
          {{:zset_entry, "product2"}, 6.45},
          {{:zset_entry, "product1"}, 8.25}
        ]
      end

      Veidrodelis.stop(pid)
    end

  end
end
