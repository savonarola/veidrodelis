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

    test "LREM replicates correctly", %{redis: redis} do
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

    test "LTRIM replicates correctly", %{redis: redis} do
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
  end
end
