defmodule Veidrodelis.Integration.StringCommandsTest do
  @moduledoc """
  Integration tests for string commands.

  Triple comparison tests: verify that Redis value, TS value, and expected value are all equal.
  """

  use ExUnit.Case, async: false
  use CommandMatchers
  use IntegrationHelpers
  require Logger

  setup do
    setup_redis()
  end

  describe "string commands" do
    @describetag timeout: 30_000

    setup %{redis: redis} do
      setup_veidrodelis(redis)
    end

    test "MSET replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["MSET", "k1", "v1", "k2", "v2"])

      assert_within 1000 do
        expected_k1 = "v1"
        expected_k2 = "v2"
        redis_k1 = Redix.command!(redis, ["GET", "k1"])
        redis_k2 = Redix.command!(redis, ["GET", "k2"])
        ts_k1 = Veidrodelis.get(vdr_id(), 0, "k1")
        ts_k2 = Veidrodelis.get(vdr_id(), 0, "k2")

        assert expected_k1 == redis_k1
        assert expected_k1 == ts_k1
        assert expected_k2 == redis_k2
        assert expected_k2 == ts_k2
      end
    end

    test "APPEND replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["SET", "append_test", "Hello"])
      Redix.command!(redis, ["APPEND", "append_test", " World"])

      assert_within 1000 do
        expected = "Hello World"
        redis_val = Redix.command!(redis, ["GET", "append_test"])
        ts_val = Veidrodelis.get(vdr_id(), 0, "append_test")

        assert expected == redis_val
        assert expected == ts_val
      end
    end

    test "RENAME replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["SET", "old_key", "rename_test"])
      Redix.command!(redis, ["RENAME", "old_key", "new_key"])

      assert_within 1000 do
        expected = "rename_test"
        redis_new = Redix.command!(redis, ["GET", "new_key"])
        redis_old = Redix.command!(redis, ["GET", "old_key"])
        ts_new = Veidrodelis.get(vdr_id(), 0, "new_key")
        ts_old = Veidrodelis.get(vdr_id(), 0, "old_key")

        assert expected == redis_new
        assert expected == ts_new
        assert nil == redis_old
        assert nil == ts_old
      end
    end

    test "RENAMENX replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["SET", "renamenx_src", "test"])
      Redix.command!(redis, ["RENAMENX", "renamenx_src", "renamenx_dst"])

      assert_within 1000 do
        expected = "test"
        redis_dst = Redix.command!(redis, ["GET", "renamenx_dst"])
        ts_dst = Veidrodelis.get(vdr_id(), 0, "renamenx_dst")

        assert expected == redis_dst
        assert expected == ts_dst
      end
    end

    test "MOVE replicates correctly", %{redis: redis} do
      # Set a key in DB 0
      Redix.command!(redis, ["SET", "move_key", "move_value"])
      # Move it to DB 1
      result = Redix.command!(redis, ["MOVE", "move_key", "1"])

      assert_within 1000 do
        expected = "move_value"

        # Key should no longer exist in DB 0
        redis_db0 = Redix.command!(redis, ["GET", "move_key"])
        ts_db0 = Veidrodelis.get(vdr_id(), 0, "move_key")
        assert nil == redis_db0
        assert nil == ts_db0

        # Key should now exist in DB 1
        Redix.command!(redis, ["SELECT", "1"])
        redis_db1 = Redix.command!(redis, ["GET", "move_key"])
        ts_db1 = Veidrodelis.get(vdr_id(), 1, "move_key")
        Redix.command!(redis, ["SELECT", "0"])

        assert expected == redis_db1
        assert expected == ts_db1
        assert 1 == result
      end
    end

    test "APPEND on empty key replicates correctly", %{redis: redis} do
      # APPEND on a non-existing key should create it
      Redix.command!(redis, ["APPEND", "new_key", "appended_content"])

      assert_within 1000 do
        expected = "appended_content"
        redis_val = Redix.command!(redis, ["GET", "new_key"])
        ts_val = Veidrodelis.get(vdr_id(), 0, "new_key")

        assert expected == redis_val
        assert expected == ts_val
      end
    end
  end
end
