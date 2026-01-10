defmodule Veidrodelis.Integration.ListCommandsTest do
  @moduledoc """
  Integration tests for list commands.

  Triple comparison tests: verify that Redis value, TS value, and expected value are all equal.
  """

  use ExUnit.Case, async: false
  use CommandMatchers
  use IntegrationHelpers
  require Logger

  setup do
    setup_redis()
  end

  describe "list commands" do
    @describetag timeout: 30_000

    setup %{redis: redis} do
      setup_veidrodelis(redis)
    end

    test "LPUSHX replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["LPUSH", "test_list", "a"])
      Redix.command!(redis, ["LPUSHX", "test_list", "b"])

      assert_within 1000 do
        expected = ["b", "a"]
        redis_list = Redix.command!(redis, ["LRANGE", "test_list", "0", "-1"])
        ts_list = Veidrodelis.lrange(vdr_id(), 0, "test_list", 0, -1)

        assert expected == redis_list
        assert expected == ts_list
        assert ts_list == redis_list
      end
    end

    test "RPUSHX replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "test_list", "a"])
      Redix.command!(redis, ["RPUSHX", "test_list", "b"])

      assert_within 1000 do
        expected = ["a", "b"]
        redis_list = Redix.command!(redis, ["LRANGE", "test_list", "0", "-1"])
        ts_list = Veidrodelis.lrange(vdr_id(), 0, "test_list", 0, -1)

        assert expected == redis_list
        assert expected == ts_list
        assert ts_list == redis_list
      end
    end

    test "LREM with positive count replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "rem_list", "x", "y", "x", "z", "x"])
      Redix.command!(redis, ["LREM", "rem_list", "2", "x"])

      assert_within 1000 do
        expected = ["y", "z", "x"]
        redis_list = Redix.command!(redis, ["LRANGE", "rem_list", "0", "-1"])
        ts_list = Veidrodelis.lrange(vdr_id(), 0, "rem_list", 0, -1)

        assert expected == redis_list
        assert expected == ts_list
        assert ts_list == redis_list
      end
    end

    test "LREM with count = 0 removes all occurrences", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "rem_all_list", "a", "x", "b", "x", "c", "x"])
      Redix.command!(redis, ["LREM", "rem_all_list", "0", "x"])

      assert_within 1000 do
        expected = ["a", "b", "c"]
        redis_list = Redix.command!(redis, ["LRANGE", "rem_all_list", "0", "-1"])
        ts_list = Veidrodelis.lrange(vdr_id(), 0, "rem_all_list", 0, -1)

        assert expected == redis_list
        assert expected == ts_list
        assert ts_list == redis_list
      end
    end

    test "LREM with negative count removes from tail", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "rem_neg_list", "x", "y", "x", "z", "x"])
      Redix.command!(redis, ["LREM", "rem_neg_list", "-2", "x"])

      assert_within 1000 do
        expected = ["x", "y", "z"]
        redis_list = Redix.command!(redis, ["LRANGE", "rem_neg_list", "0", "-1"])
        ts_list = Veidrodelis.lrange(vdr_id(), 0, "rem_neg_list", 0, -1)

        assert expected == redis_list
        assert expected == ts_list
        assert ts_list == redis_list
      end
    end

    test "LTRIM with positive indices replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "trim_list", "a", "b", "c", "d", "e"])
      Redix.command!(redis, ["LTRIM", "trim_list", "1", "3"])

      assert_within 1000 do
        expected = ["b", "c", "d"]
        redis_list = Redix.command!(redis, ["LRANGE", "trim_list", "0", "-1"])
        ts_list = Veidrodelis.lrange(vdr_id(), 0, "trim_list", 0, -1)

        assert expected == redis_list
        assert expected == ts_list
        assert ts_list == redis_list
      end
    end

    test "LTRIM with negative start index replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "trim_neg_start", "a", "b", "c", "d", "e"])
      Redix.command!(redis, ["LTRIM", "trim_neg_start", "-3", "-1"])

      assert_within 1000 do
        expected = ["c", "d", "e"]
        redis_list = Redix.command!(redis, ["LRANGE", "trim_neg_start", "0", "-1"])
        ts_list = Veidrodelis.lrange(vdr_id(), 0, "trim_neg_start", 0, -1)

        assert expected == redis_list
        assert expected == ts_list
        assert ts_list == redis_list
      end
    end

    test "LTRIM with negative stop index replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "trim_neg_stop", "a", "b", "c", "d", "e"])
      Redix.command!(redis, ["LTRIM", "trim_neg_stop", "1", "-2"])

      assert_within 1000 do
        expected = ["b", "c", "d"]
        redis_list = Redix.command!(redis, ["LRANGE", "trim_neg_stop", "0", "-1"])
        ts_list = Veidrodelis.lrange(vdr_id(), 0, "trim_neg_stop", 0, -1)

        assert expected == redis_list
        assert expected == ts_list
        assert ts_list == redis_list
      end
    end

    test "LTRIM with both negative indices replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "trim_both_neg", "a", "b", "c", "d", "e"])
      Redix.command!(redis, ["LTRIM", "trim_both_neg", "-4", "-2"])

      assert_within 1000 do
        expected = ["b", "c", "d"]
        redis_list = Redix.command!(redis, ["LRANGE", "trim_both_neg", "0", "-1"])
        ts_list = Veidrodelis.lrange(vdr_id(), 0, "trim_both_neg", 0, -1)

        assert expected == redis_list
        assert expected == ts_list
        assert ts_list == redis_list
      end
    end

    test "LINSERT replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "insert_list", "a", "c"])
      Redix.command!(redis, ["LINSERT", "insert_list", "BEFORE", "c", "b"])

      assert_within 1000 do
        expected = ["a", "b", "c"]
        redis_list = Redix.command!(redis, ["LRANGE", "insert_list", "0", "-1"])
        ts_list = Veidrodelis.lrange(vdr_id(), 0, "insert_list", 0, -1)

        assert expected == redis_list
        assert expected == ts_list
        assert ts_list == redis_list
      end
    end

    test "LSET with positive index replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "set_list", "a", "b", "c", "d"])
      Redix.command!(redis, ["LSET", "set_list", "2", "X"])

      assert_within 1000 do
        expected = ["a", "b", "X", "d"]
        redis_list = Redix.command!(redis, ["LRANGE", "set_list", "0", "-1"])
        ts_list = Veidrodelis.lrange(vdr_id(), 0, "set_list", 0, -1)

        assert expected == redis_list
        assert expected == ts_list
        assert ts_list == redis_list
      end
    end

    test "LSET with negative index replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "set_neg_list", "a", "b", "c", "d"])
      Redix.command!(redis, ["LSET", "set_neg_list", "-2", "Y"])

      assert_within 1000 do
        expected = ["a", "b", "Y", "d"]
        redis_list = Redix.command!(redis, ["LRANGE", "set_neg_list", "0", "-1"])
        ts_list = Veidrodelis.lrange(vdr_id(), 0, "set_neg_list", 0, -1)

        assert expected == redis_list
        assert expected == ts_list
        assert ts_list == redis_list
      end
    end

    test "LSET with last element using -1 replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "set_last_list", "a", "b", "c"])
      Redix.command!(redis, ["LSET", "set_last_list", "-1", "Z"])

      assert_within 1000 do
        expected = ["a", "b", "Z"]
        redis_list = Redix.command!(redis, ["LRANGE", "set_last_list", "0", "-1"])
        ts_list = Veidrodelis.lrange(vdr_id(), 0, "set_last_list", 0, -1)

        assert expected == redis_list
        assert expected == ts_list
        assert ts_list == redis_list
      end
    end

    test "RPOPLPUSH between different keys replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "src_list", "a", "b", "c"])
      Redix.command!(redis, ["RPUSH", "dest_list", "x", "y"])
      Redix.command!(redis, ["RPOPLPUSH", "src_list", "dest_list"])

      assert_within 1000 do
        expected_src = ["a", "b"]
        expected_dest = ["c", "x", "y"]

        redis_src = Redix.command!(redis, ["LRANGE", "src_list", "0", "-1"])
        redis_dest = Redix.command!(redis, ["LRANGE", "dest_list", "0", "-1"])
        ts_src = Veidrodelis.lrange(vdr_id(), 0, "src_list", 0, -1)
        ts_dest = Veidrodelis.lrange(vdr_id(), 0, "dest_list", 0, -1)

        assert expected_src == redis_src
        assert expected_src == ts_src
        assert ts_src == redis_src

        assert expected_dest == redis_dest
        assert expected_dest == ts_dest
        assert ts_dest == redis_dest
      end
    end

    test "RPOPLPUSH with same source and destination (circular) replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "circular_list", "a", "b", "c"])
      Redix.command!(redis, ["RPOPLPUSH", "circular_list", "circular_list"])

      assert_within 1000 do
        expected = ["c", "a", "b"]
        redis_list = Redix.command!(redis, ["LRANGE", "circular_list", "0", "-1"])
        ts_list = Veidrodelis.lrange(vdr_id(), 0, "circular_list", 0, -1)

        assert expected == redis_list
        assert expected == ts_list
        assert ts_list == redis_list
      end
    end

    test "RPOPLPUSH with same key multiple times replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["RPUSH", "rotate_list", "a", "b", "c", "d"])
      Redix.command!(redis, ["RPOPLPUSH", "rotate_list", "rotate_list"])
      Redix.command!(redis, ["RPOPLPUSH", "rotate_list", "rotate_list"])

      assert_within 1000 do
        expected = ["c", "d", "a", "b"]
        redis_list = Redix.command!(redis, ["LRANGE", "rotate_list", "0", "-1"])
        ts_list = Veidrodelis.lrange(vdr_id(), 0, "rotate_list", 0, -1)

        assert expected == redis_list
        assert expected == ts_list
        assert ts_list == redis_list
      end
    end
  end
end
