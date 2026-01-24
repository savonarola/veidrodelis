defmodule Veidrodelis.Integration.GenericCommandsTest do
  @moduledoc """
  Integration tests for generic commands that work across all data types.

  Triple comparison tests: verify that Redis value, TS value, and expected value are all equal.
  Tests for MOVE, COPY, UNLINK, FLUSHDB, FLUSHALL, and SWAPDB commands.
  """

  use ExUnit.Case, async: false
  use CommandMatchers
  use IntegrationHelpers
  require Logger

  setup do
    setup_redis()
  end

  describe "MOVE command" do
    @describetag timeout: 30_000

    setup %{redis: redis} do
      setup_veidrodelis(redis)
    end

    test "MOVE string key to another database", %{redis: redis} do
      Redix.command!(redis, ["SET", "move_string", "hello"])
      result = Redix.command!(redis, ["MOVE", "move_string", "1"])

      assert_within 1000 do
        expected = "hello"

        # Key should no longer exist in DB 0
        redis_db0 = Redix.command!(redis, ["GET", "move_string"])
        {:ok, ts_db0} = Veidrodelis.get(vdr_id(), 0, "move_string")
        assert nil == redis_db0
        assert nil == ts_db0

        # Key should now exist in DB 1
        Redix.command!(redis, ["SELECT", "1"])
        redis_db1 = Redix.command!(redis, ["GET", "move_string"])
        {:ok, ts_db1} = Veidrodelis.get(vdr_id(), 1, "move_string")
        Redix.command!(redis, ["SELECT", "0"])

        assert expected == redis_db1
        assert expected == ts_db1
        assert 1 == result
      end
    end

    test "MOVE list to another database", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "move_list", "a", "b", "c"])
      result = Redix.command!(redis, ["MOVE", "move_list", "2"])

      assert_within 1000 do
        expected = ["a", "b", "c"]

        # Key should no longer exist in DB 0
        redis_db0 = Redix.command!(redis, ["LRANGE", "move_list", "0", "-1"])
        {:ok, ts_db0} = Veidrodelis.lrange(vdr_id(), 0, "move_list", 0, -1)
        assert [] == redis_db0
        assert [] == ts_db0

        # Key should now exist in DB 2
        Redix.command!(redis, ["SELECT", "2"])
        redis_db2 = Redix.command!(redis, ["LRANGE", "move_list", "0", "-1"])
        {:ok, ts_db2} = Veidrodelis.lrange(vdr_id(), 2, "move_list", 0, -1)
        Redix.command!(redis, ["SELECT", "0"])

        assert expected == redis_db2
        assert expected == ts_db2
        assert 1 == result
      end
    end

    test "MOVE set to another database", %{redis: redis} do
      Redix.command!(redis, ["SADD", "move_set", "x", "y", "z"])
      result = Redix.command!(redis, ["MOVE", "move_set", "3"])

      assert_within 1000 do
        expected = ["x", "y", "z"]

        # Key should no longer exist in DB 0
        redis_db0 = Redix.command!(redis, ["SMEMBERS", "move_set"]) |> Enum.sort()
        {:ok, ts_db0_temp} = Veidrodelis.smembers(vdr_id(), 0, "move_set")
        ts_db0 = Enum.sort(ts_db0_temp)
        assert [] == redis_db0
        assert [] == ts_db0

        # Key should now exist in DB 3
        Redix.command!(redis, ["SELECT", "3"])
        redis_db3 = Redix.command!(redis, ["SMEMBERS", "move_set"]) |> Enum.sort()
        {:ok, ts_db3_temp} = Veidrodelis.smembers(vdr_id(), 3, "move_set")
        ts_db3 = Enum.sort(ts_db3_temp)
        Redix.command!(redis, ["SELECT", "0"])

        assert expected == redis_db3
        assert expected == ts_db3
        assert 1 == result
      end
    end

    test "MOVE hash to another database", %{redis: redis} do
      Redix.command!(redis, ["HSET", "move_hash", "field1", "value1", "field2", "value2"])
      result = Redix.command!(redis, ["MOVE", "move_hash", "4"])

      assert_within 1000 do
        expected_map = %{"field1" => "value1", "field2" => "value2"}

        # Key should no longer exist in DB 0
        redis_db0 = Redix.command!(redis, ["HGETALL", "move_hash"])
        {:ok, ts_db0} = Veidrodelis.hgetall(vdr_id(), 0, "move_hash")
        assert [] == redis_db0
        assert [] == ts_db0

        # Key should now exist in DB 4
        Redix.command!(redis, ["SELECT", "4"])

        redis_db4 =
          Redix.command!(redis, ["HGETALL", "move_hash"])
          |> Enum.chunk_every(2)
          |> Map.new(fn [k, v] -> {k, v} end)

        {:ok, ts_db4_temp} = Veidrodelis.hgetall(vdr_id(), 4, "move_hash")
        ts_db4 = Map.new(ts_db4_temp)
        Redix.command!(redis, ["SELECT", "0"])

        assert expected_map == redis_db4
        assert expected_map == ts_db4
        assert 1 == result
      end
    end

    test "MOVE sorted set to another database", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "move_zset", "1.0", "one", "2.0", "two", "3.0", "three"])
      result = Redix.command!(redis, ["MOVE", "move_zset", "5"])

      assert_within 1000 do
        expected = ["one", "two", "three"]

        # Key should no longer exist in DB 0
        redis_db0 = Redix.command!(redis, ["ZRANGE", "move_zset", "0", "-1"])
        {:ok, ts_db0} = Veidrodelis.zrange(vdr_id(), 0, "move_zset", 0, -1, false)
        assert [] == redis_db0
        assert [] == ts_db0

        # Key should now exist in DB 5
        Redix.command!(redis, ["SELECT", "5"])
        redis_db5 = Redix.command!(redis, ["ZRANGE", "move_zset", "0", "-1"])
        {:ok, ts_db5} = Veidrodelis.zrange(vdr_id(), 5, "move_zset", 0, -1, false)
        Redix.command!(redis, ["SELECT", "0"])

        assert expected == redis_db5
        assert expected == ts_db5
        assert 1 == result
      end
    end

    test "MOVE fails when destination key exists", %{redis: redis} do
      Redix.command!(redis, ["SET", "move_src", "value"])
      Redix.command!(redis, ["SELECT", "6"])
      Redix.command!(redis, ["SET", "move_src", "existing"])
      Redix.command!(redis, ["SELECT", "0"])

      result = Redix.command!(redis, ["MOVE", "move_src", "6"])

      assert_within 1000 do
        # Source should still exist in DB 0
        redis_db0 = Redix.command!(redis, ["GET", "move_src"])
        {:ok, ts_db0} = Veidrodelis.get(vdr_id(), 0, "move_src")
        assert "value" == redis_db0
        assert "value" == ts_db0

        # Destination should be unchanged in DB 6
        Redix.command!(redis, ["SELECT", "6"])
        redis_db6 = Redix.command!(redis, ["GET", "move_src"])
        {:ok, ts_db6} = Veidrodelis.get(vdr_id(), 6, "move_src")
        Redix.command!(redis, ["SELECT", "0"])

        assert "existing" == redis_db6
        assert "existing" == ts_db6
        assert 0 == result
      end
    end

    test "MOVE non-existent key does nothing", %{redis: redis} do
      result = Redix.command!(redis, ["MOVE", "nonexistent", "1"])

      assert_within 1000 do
        assert 0 == result
      end
    end
  end

  describe "COPY command" do
    @describetag timeout: 30_000

    setup %{redis: redis} do
      setup_veidrodelis(redis)
    end

    test "COPY string to new key", %{redis: redis} do
      Redix.command!(redis, ["SET", "copy_src_str", "hello world"])
      result = Redix.command!(redis, ["COPY", "copy_src_str", "copy_dst_str"])

      assert_within 1000 do
        expected = "hello world"

        # Source should still exist
        redis_src = Redix.command!(redis, ["GET", "copy_src_str"])
        {:ok, ts_src} = Veidrodelis.get(vdr_id(), 0, "copy_src_str")
        assert expected == redis_src
        assert expected == ts_src

        # Destination should have the copied value
        redis_dst = Redix.command!(redis, ["GET", "copy_dst_str"])
        {:ok, ts_dst} = Veidrodelis.get(vdr_id(), 0, "copy_dst_str")
        assert expected == redis_dst
        assert expected == ts_dst
        assert 1 == result
      end
    end

    test "COPY list to new key", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "copy_src_list", "a", "b", "c"])
      result = Redix.command!(redis, ["COPY", "copy_src_list", "copy_dst_list"])

      assert_within 1000 do
        expected = ["a", "b", "c"]

        # Source should still exist
        redis_src = Redix.command!(redis, ["LRANGE", "copy_src_list", "0", "-1"])
        {:ok, ts_src} = Veidrodelis.lrange(vdr_id(), 0, "copy_src_list", 0, -1)
        assert expected == redis_src
        assert expected == ts_src

        # Destination should have the copied value
        redis_dst = Redix.command!(redis, ["LRANGE", "copy_dst_list", "0", "-1"])
        {:ok, ts_dst} = Veidrodelis.lrange(vdr_id(), 0, "copy_dst_list", 0, -1)
        assert expected == redis_dst
        assert expected == ts_dst
        assert 1 == result
      end
    end

    test "COPY set to new key", %{redis: redis} do
      Redix.command!(redis, ["SADD", "copy_src_set", "x", "y", "z"])
      result = Redix.command!(redis, ["COPY", "copy_src_set", "copy_dst_set"])

      assert_within 1000 do
        expected = ["x", "y", "z"]

        # Source should still exist
        redis_src = Redix.command!(redis, ["SMEMBERS", "copy_src_set"]) |> Enum.sort()
        {:ok, ts_src_temp} = Veidrodelis.smembers(vdr_id(), 0, "copy_src_set")
        ts_src = Enum.sort(ts_src_temp)
        assert expected == redis_src
        assert expected == ts_src

        # Destination should have the copied value
        redis_dst = Redix.command!(redis, ["SMEMBERS", "copy_dst_set"]) |> Enum.sort()
        {:ok, ts_dst_temp} = Veidrodelis.smembers(vdr_id(), 0, "copy_dst_set")
        ts_dst = Enum.sort(ts_dst_temp)
        assert expected == redis_dst
        assert expected == ts_dst
        assert 1 == result
      end
    end

    test "COPY hash to new key", %{redis: redis} do
      Redix.command!(redis, ["HSET", "copy_src_hash", "f1", "v1", "f2", "v2"])
      result = Redix.command!(redis, ["COPY", "copy_src_hash", "copy_dst_hash"])

      assert_within 1000 do
        expected = %{"f1" => "v1", "f2" => "v2"}

        # Source should still exist
        redis_src =
          Redix.command!(redis, ["HGETALL", "copy_src_hash"])
          |> Enum.chunk_every(2)
          |> Map.new(fn [k, v] -> {k, v} end)

        {:ok, ts_src_temp} = Veidrodelis.hgetall(vdr_id(), 0, "copy_src_hash")
        ts_src = Map.new(ts_src_temp)
        assert expected == redis_src
        assert expected == ts_src

        # Destination should have the copied value
        redis_dst =
          Redix.command!(redis, ["HGETALL", "copy_dst_hash"])
          |> Enum.chunk_every(2)
          |> Map.new(fn [k, v] -> {k, v} end)

        {:ok, ts_dst_temp} = Veidrodelis.hgetall(vdr_id(), 0, "copy_dst_hash")
        ts_dst = Map.new(ts_dst_temp)
        assert expected == redis_dst
        assert expected == ts_dst
        assert 1 == result
      end
    end

    test "COPY sorted set to new key", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "copy_src_zset", "1.5", "m1", "2.5", "m2", "3.5", "m3"])
      result = Redix.command!(redis, ["COPY", "copy_src_zset", "copy_dst_zset"])

      assert_within 1000 do
        expected = ["m1", "m2", "m3"]

        # Source should still exist
        redis_src = Redix.command!(redis, ["ZRANGE", "copy_src_zset", "0", "-1"])
        {:ok, ts_src} = Veidrodelis.zrange(vdr_id(), 0, "copy_src_zset", 0, -1, false)
        assert expected == redis_src
        assert expected == ts_src

        # Destination should have the copied value
        redis_dst = Redix.command!(redis, ["ZRANGE", "copy_dst_zset", "0", "-1"])
        {:ok, ts_dst} = Veidrodelis.zrange(vdr_id(), 0, "copy_dst_zset", 0, -1, false)
        assert expected == redis_dst
        assert expected == ts_dst
        assert 1 == result
      end
    end

    test "COPY with REPLACE overwrites existing key", %{redis: redis} do
      Redix.command!(redis, ["SET", "copy_replace_src", "new_value"])
      Redix.command!(redis, ["SET", "copy_replace_dst", "old_value"])
      result = Redix.command!(redis, ["COPY", "copy_replace_src", "copy_replace_dst", "REPLACE"])

      assert_within 1000 do
        expected = "new_value"

        # Destination should have the copied value
        redis_dst = Redix.command!(redis, ["GET", "copy_replace_dst"])
        {:ok, ts_dst} = Veidrodelis.get(vdr_id(), 0, "copy_replace_dst")
        assert expected == redis_dst
        assert expected == ts_dst
        assert 1 == result
      end
    end

    test "COPY without REPLACE fails when destination exists", %{redis: redis} do
      Redix.command!(redis, ["SET", "copy_noreplace_src", "new_value"])
      Redix.command!(redis, ["SET", "copy_noreplace_dst", "old_value"])
      result = Redix.command!(redis, ["COPY", "copy_noreplace_src", "copy_noreplace_dst"])

      assert_within 1000 do
        # Destination should be unchanged
        redis_dst = Redix.command!(redis, ["GET", "copy_noreplace_dst"])
        {:ok, ts_dst} = Veidrodelis.get(vdr_id(), 0, "copy_noreplace_dst")
        assert "old_value" == redis_dst
        assert "old_value" == ts_dst
        assert 0 == result
      end
    end

    test "COPY non-existent key does nothing", %{redis: redis} do
      result = Redix.command!(redis, ["COPY", "nonexistent_copy", "copy_dst_nonexist"])

      assert_within 1000 do
        assert 0 == result
        redis_dst = Redix.command!(redis, ["GET", "copy_dst_nonexist"])
        {:ok, ts_dst} = Veidrodelis.get(vdr_id(), 0, "copy_dst_nonexist")
        assert nil == redis_dst
        assert nil == ts_dst
      end
    end
  end

  describe "UNLINK command" do
    @describetag timeout: 30_000

    setup %{redis: redis} do
      setup_veidrodelis(redis)
    end

    test "UNLINK single string key", %{redis: redis} do
      Redix.command!(redis, ["SET", "unlink_str", "test_value"])
      result = Redix.command!(redis, ["UNLINK", "unlink_str"])

      assert_within 1000 do
        redis_val = Redix.command!(redis, ["GET", "unlink_str"])
        {:ok, ts_val} = Veidrodelis.get(vdr_id(), 0, "unlink_str")
        assert nil == redis_val
        assert nil == ts_val
        assert 1 == result
      end
    end

    test "UNLINK multiple keys", %{redis: redis} do
      Redix.command!(redis, ["SET", "unlink_m1", "v1"])
      Redix.command!(redis, ["SET", "unlink_m2", "v2"])
      Redix.command!(redis, ["SET", "unlink_m3", "v3"])
      result = Redix.command!(redis, ["UNLINK", "unlink_m1", "unlink_m2", "unlink_m3"])

      assert_within 1000 do
        redis_v1 = Redix.command!(redis, ["GET", "unlink_m1"])
        redis_v2 = Redix.command!(redis, ["GET", "unlink_m2"])
        redis_v3 = Redix.command!(redis, ["GET", "unlink_m3"])
        {:ok, ts_v1} = Veidrodelis.get(vdr_id(), 0, "unlink_m1")
        {:ok, ts_v2} = Veidrodelis.get(vdr_id(), 0, "unlink_m2")
        {:ok, ts_v3} = Veidrodelis.get(vdr_id(), 0, "unlink_m3")

        assert nil == redis_v1
        assert nil == redis_v2
        assert nil == redis_v3
        assert nil == ts_v1
        assert nil == ts_v2
        assert nil == ts_v3
        assert 3 == result
      end
    end

    test "UNLINK list", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "unlink_list", "a", "b", "c", "d", "e"])
      result = Redix.command!(redis, ["UNLINK", "unlink_list"])

      assert_within 1000 do
        redis_val = Redix.command!(redis, ["LRANGE", "unlink_list", "0", "-1"])
        {:ok, ts_val} = Veidrodelis.lrange(vdr_id(), 0, "unlink_list", 0, -1)
        assert [] == redis_val
        assert [] == ts_val
        assert 1 == result
      end
    end

    test "UNLINK set", %{redis: redis} do
      Redix.command!(redis, ["SADD", "unlink_set", "x", "y", "z", "w"])
      result = Redix.command!(redis, ["UNLINK", "unlink_set"])

      assert_within 1000 do
        redis_val = Redix.command!(redis, ["SMEMBERS", "unlink_set"])
        {:ok, ts_val} = Veidrodelis.smembers(vdr_id(), 0, "unlink_set")
        assert [] == redis_val
        assert [] == ts_val
        assert 1 == result
      end
    end

    test "UNLINK hash", %{redis: redis} do
      Redix.command!(redis, ["HSET", "unlink_hash", "field1", "val1", "field2", "val2"])
      result = Redix.command!(redis, ["UNLINK", "unlink_hash"])

      assert_within 1000 do
        redis_val = Redix.command!(redis, ["HGETALL", "unlink_hash"])
        {:ok, ts_val} = Veidrodelis.hgetall(vdr_id(), 0, "unlink_hash")
        assert [] == redis_val
        assert [] == ts_val
        assert 1 == result
      end
    end

    test "UNLINK sorted set", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "unlink_zset", "1.0", "one", "2.0", "two", "3.0", "three"])
      result = Redix.command!(redis, ["UNLINK", "unlink_zset"])

      assert_within 1000 do
        redis_val = Redix.command!(redis, ["ZRANGE", "unlink_zset", "0", "-1"])
        {:ok, ts_val} = Veidrodelis.zrange(vdr_id(), 0, "unlink_zset", 0, -1, false)
        assert [] == redis_val
        assert [] == ts_val
        assert 1 == result
      end
    end

    test "UNLINK non-existent key does nothing", %{redis: redis} do
      result = Redix.command!(redis, ["UNLINK", "nonexistent_unlink"])

      assert_within 1000 do
        assert 0 == result
      end
    end

    test "UNLINK with mix of existent and non-existent keys", %{redis: redis} do
      Redix.command!(redis, ["SET", "unlink_exists1", "value"])
      Redix.command!(redis, ["SET", "unlink_exists2", "value"])

      result =
        Redix.command!(redis, [
          "UNLINK",
          "unlink_exists1",
          "nonexistent1",
          "unlink_exists2",
          "nonexistent2"
        ])

      assert_within 1000 do
        redis_v1 = Redix.command!(redis, ["GET", "unlink_exists1"])
        redis_v2 = Redix.command!(redis, ["GET", "unlink_exists2"])
        {:ok, ts_v1} = Veidrodelis.get(vdr_id(), 0, "unlink_exists1")
        {:ok, ts_v2} = Veidrodelis.get(vdr_id(), 0, "unlink_exists2")

        assert nil == redis_v1
        assert nil == redis_v2
        assert nil == ts_v1
        assert nil == ts_v2
        assert 2 == result
      end
    end

    test "UNLINK different data types in one command", %{redis: redis} do
      Redix.command!(redis, ["SET", "unlink_mixed_str", "string"])
      Redix.command!(redis, ["RPUSH", "unlink_mixed_list", "a", "b"])
      Redix.command!(redis, ["SADD", "unlink_mixed_set", "x", "y"])
      Redix.command!(redis, ["HSET", "unlink_mixed_hash", "f", "v"])
      Redix.command!(redis, ["ZADD", "unlink_mixed_zset", "1.0", "member"])

      result =
        Redix.command!(redis, [
          "UNLINK",
          "unlink_mixed_str",
          "unlink_mixed_list",
          "unlink_mixed_set",
          "unlink_mixed_hash",
          "unlink_mixed_zset"
        ])

      assert_within 1000 do
        assert nil == Redix.command!(redis, ["GET", "unlink_mixed_str"])
        assert [] == Redix.command!(redis, ["LRANGE", "unlink_mixed_list", "0", "-1"])
        assert [] == Redix.command!(redis, ["SMEMBERS", "unlink_mixed_set"])
        assert [] == Redix.command!(redis, ["HGETALL", "unlink_mixed_hash"])
        assert [] == Redix.command!(redis, ["ZRANGE", "unlink_mixed_zset", "0", "-1"])

        assert {:ok, nil} == Veidrodelis.get(vdr_id(), 0, "unlink_mixed_str")
        assert {:ok, []} == Veidrodelis.lrange(vdr_id(), 0, "unlink_mixed_list", 0, -1)
        assert {:ok, []} == Veidrodelis.smembers(vdr_id(), 0, "unlink_mixed_set")
        assert {:ok, []} == Veidrodelis.hgetall(vdr_id(), 0, "unlink_mixed_hash")
        assert {:ok, []} == Veidrodelis.zrange(vdr_id(), 0, "unlink_mixed_zset", 0, -1, false)

        assert 5 == result
      end
    end
  end

  describe "FLUSHDB command" do
    @describetag timeout: 30_000

    setup %{redis: redis} do
      setup_veidrodelis(redis)
    end

    test "FLUSHDB clears all keys in current database", %{redis: redis} do
      # Set up keys in DB 0
      Redix.command!(redis, ["SET", "flushdb_str", "value"])
      Redix.command!(redis, ["RPUSH", "flushdb_list", "a", "b"])
      Redix.command!(redis, ["SADD", "flushdb_set", "x", "y"])

      # Set up key in DB 1 (should not be affected)
      Redix.command!(redis, ["SELECT", "1"])
      Redix.command!(redis, ["SET", "flushdb_other", "keep_me"])
      Redix.command!(redis, ["SELECT", "0"])

      # Wait for replication
      assert_within 1000 do
        assert {:ok, "value"} == Veidrodelis.get(vdr_id(), 0, "flushdb_str")
        assert {:ok, "keep_me"} == Veidrodelis.get(vdr_id(), 1, "flushdb_other")
      end

      # Flush DB 0
      Redix.command!(redis, ["FLUSHDB"])

      assert_within 1000 do
        # DB 0 should be empty
        assert nil == Redix.command!(redis, ["GET", "flushdb_str"])
        assert {:ok, nil} == Veidrodelis.get(vdr_id(), 0, "flushdb_str")
        assert {:ok, []} == Veidrodelis.lrange(vdr_id(), 0, "flushdb_list", 0, -1)
        assert {:ok, []} == Veidrodelis.smembers(vdr_id(), 0, "flushdb_set")

        # DB 1 should be unchanged
        Redix.command!(redis, ["SELECT", "1"])
        assert "keep_me" == Redix.command!(redis, ["GET", "flushdb_other"])
        Redix.command!(redis, ["SELECT", "0"])
        assert {:ok, "keep_me"} == Veidrodelis.get(vdr_id(), 1, "flushdb_other")
      end
    end

    test "FLUSHDB triggers watch notifications for affected database", %{redis: redis} do
      ref_db0 = make_ref()
      ref_db1 = make_ref()

      # Set up keys
      Redix.command!(redis, ["SET", "flushdb_watch_key", "value"])
      Redix.command!(redis, ["SELECT", "1"])
      Redix.command!(redis, ["SET", "flushdb_watch_other", "value"])
      Redix.command!(redis, ["SELECT", "0"])

      # Wait for replication
      assert_within 1000 do
        assert {:ok, "value"} == Veidrodelis.get(vdr_id(), 0, "flushdb_watch_key")
      end

      # Watch keys in both databases
      :ok = Veidrodelis.watch(vdr_id(), 0, "flushdb_watch_key", ref_db0)
      :ok = Veidrodelis.watch(vdr_id(), 1, "flushdb_watch_other", ref_db1)

      # Flush DB 0
      Redix.command!(redis, ["FLUSHDB"])

      # DB 0 watcher should receive notification
      assert_receive {^ref_db0, %Vdr.WatchEvent.Update{command: {:flushdb}, db: 0}}, 2000

      # DB 1 watcher should NOT receive notification
      refute_receive {^ref_db1, _}, 500
    end
  end

  describe "FLUSHALL command" do
    @describetag timeout: 30_000

    setup %{redis: redis} do
      setup_veidrodelis(redis)
    end

    test "FLUSHALL clears all keys in all databases", %{redis: redis} do
      # Set up keys in multiple databases
      Redix.command!(redis, ["SET", "flushall_db0", "value0"])
      Redix.command!(redis, ["SELECT", "1"])
      Redix.command!(redis, ["SET", "flushall_db1", "value1"])
      Redix.command!(redis, ["SELECT", "2"])
      Redix.command!(redis, ["SET", "flushall_db2", "value2"])
      Redix.command!(redis, ["SELECT", "0"])

      # Wait for replication
      assert_within 1000 do
        assert {:ok, "value0"} == Veidrodelis.get(vdr_id(), 0, "flushall_db0")
        assert {:ok, "value1"} == Veidrodelis.get(vdr_id(), 1, "flushall_db1")
        assert {:ok, "value2"} == Veidrodelis.get(vdr_id(), 2, "flushall_db2")
      end

      # Flush all databases
      Redix.command!(redis, ["FLUSHALL"])

      assert_within 1000 do
        # All databases should be empty
        assert {:ok, nil} == Veidrodelis.get(vdr_id(), 0, "flushall_db0")
        assert {:ok, nil} == Veidrodelis.get(vdr_id(), 1, "flushall_db1")
        assert {:ok, nil} == Veidrodelis.get(vdr_id(), 2, "flushall_db2")

        # Verify in Redis too
        assert nil == Redix.command!(redis, ["GET", "flushall_db0"])
        Redix.command!(redis, ["SELECT", "1"])
        assert nil == Redix.command!(redis, ["GET", "flushall_db1"])
        Redix.command!(redis, ["SELECT", "2"])
        assert nil == Redix.command!(redis, ["GET", "flushall_db2"])
        Redix.command!(redis, ["SELECT", "0"])
      end
    end

    test "FLUSHALL triggers watch notifications for all databases", %{redis: redis} do
      ref_db0 = make_ref()
      ref_db1 = make_ref()

      # Set up keys
      Redix.command!(redis, ["SET", "flushall_watch_0", "value"])
      Redix.command!(redis, ["SELECT", "1"])
      Redix.command!(redis, ["SET", "flushall_watch_1", "value"])
      Redix.command!(redis, ["SELECT", "0"])

      # Wait for replication
      assert_within 1000 do
        assert {:ok, "value"} == Veidrodelis.get(vdr_id(), 0, "flushall_watch_0")
        assert {:ok, "value"} == Veidrodelis.get(vdr_id(), 1, "flushall_watch_1")
      end

      # Watch keys in both databases
      :ok = Veidrodelis.watch(vdr_id(), 0, "flushall_watch_0", ref_db0)
      :ok = Veidrodelis.watch(vdr_id(), 1, "flushall_watch_1", ref_db1)

      # Flush all databases
      Redix.command!(redis, ["FLUSHALL"])

      # Both watchers should receive notifications
      assert_receive {^ref_db0, %Vdr.WatchEvent.Update{command: {:flushall}}}, 2000
      assert_receive {^ref_db1, %Vdr.WatchEvent.Update{command: {:flushall}}}, 2000
    end
  end

  describe "SWAPDB command" do
    @describetag timeout: 30_000

    setup %{redis: redis} do
      setup_veidrodelis(redis)
    end

    test "SWAPDB swaps contents of two databases", %{redis: redis} do
      # Set up keys in DB 0
      Redix.command!(redis, ["SET", "swap_key_a", "from_db0"])
      Redix.command!(redis, ["RPUSH", "swap_list", "db0_item"])

      # Set up keys in DB 1
      Redix.command!(redis, ["SELECT", "1"])
      Redix.command!(redis, ["SET", "swap_key_b", "from_db1"])
      Redix.command!(redis, ["SELECT", "0"])

      # Wait for replication
      assert_within 1000 do
        assert {:ok, "from_db0"} == Veidrodelis.get(vdr_id(), 0, "swap_key_a")
        assert {:ok, "from_db1"} == Veidrodelis.get(vdr_id(), 1, "swap_key_b")
      end

      # Swap DB 0 and DB 1
      Redix.command!(redis, ["SWAPDB", "0", "1"])

      assert_within 1000 do
        # DB 0 now has DB 1's content
        assert {:ok, "from_db1"} == Veidrodelis.get(vdr_id(), 0, "swap_key_b")
        assert {:ok, nil} == Veidrodelis.get(vdr_id(), 0, "swap_key_a")

        # DB 1 now has DB 0's content
        assert {:ok, "from_db0"} == Veidrodelis.get(vdr_id(), 1, "swap_key_a")
        assert {:ok, ["db0_item"]} == Veidrodelis.lrange(vdr_id(), 1, "swap_list", 0, -1)
        assert {:ok, nil} == Veidrodelis.get(vdr_id(), 1, "swap_key_b")

        # Verify in Redis
        assert "from_db1" == Redix.command!(redis, ["GET", "swap_key_b"])
        Redix.command!(redis, ["SELECT", "1"])
        assert "from_db0" == Redix.command!(redis, ["GET", "swap_key_a"])
        Redix.command!(redis, ["SELECT", "0"])
      end
    end

    test "SWAPDB triggers watch notifications for both databases", %{redis: redis} do
      ref_db0 = make_ref()
      ref_db1 = make_ref()

      # Set up keys
      Redix.command!(redis, ["SET", "swap_watch_0", "value0"])
      Redix.command!(redis, ["SELECT", "1"])
      Redix.command!(redis, ["SET", "swap_watch_1", "value1"])
      Redix.command!(redis, ["SELECT", "0"])

      # Wait for replication
      assert_within 1000 do
        assert {:ok, "value0"} == Veidrodelis.get(vdr_id(), 0, "swap_watch_0")
        assert {:ok, "value1"} == Veidrodelis.get(vdr_id(), 1, "swap_watch_1")
      end

      # Watch keys in both databases
      :ok = Veidrodelis.watch(vdr_id(), 0, "swap_watch_0", ref_db0)
      :ok = Veidrodelis.watch(vdr_id(), 1, "swap_watch_1", ref_db1)

      # Swap databases
      Redix.command!(redis, ["SWAPDB", "0", "1"])

      # Both watchers should receive notifications
      assert_receive {^ref_db0, %Vdr.WatchEvent.Update{command: {:swapdb, 0, 1}}}, 2000
      assert_receive {^ref_db1, %Vdr.WatchEvent.Update{command: {:swapdb, 0, 1}}}, 2000
    end

    test "SWAPDB with one empty database", %{redis: redis} do
      # Set up keys only in DB 0
      Redix.command!(redis, ["SET", "swap_only_0", "in_db0"])

      # Ensure DB 3 is empty
      Redix.command!(redis, ["SELECT", "3"])
      Redix.command!(redis, ["FLUSHDB"])
      Redix.command!(redis, ["SELECT", "0"])

      # Wait for replication
      assert_within 1000 do
        assert {:ok, "in_db0"} == Veidrodelis.get(vdr_id(), 0, "swap_only_0")
      end

      # Swap DB 0 and DB 3
      Redix.command!(redis, ["SWAPDB", "0", "3"])

      assert_within 1000 do
        # DB 0 is now empty
        assert {:ok, nil} == Veidrodelis.get(vdr_id(), 0, "swap_only_0")

        # DB 3 now has DB 0's content
        assert {:ok, "in_db0"} == Veidrodelis.get(vdr_id(), 3, "swap_only_0")
      end
    end
  end
end
