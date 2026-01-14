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

    test "SETRANGE replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["SET", "range_key", "Hello World"])
      Redix.command!(redis, ["SETRANGE", "range_key", "6", "Redis"])

      assert_within 1000 do
        expected = "Hello Redis"
        redis_val = Redix.command!(redis, ["GET", "range_key"])
        ts_val = Veidrodelis.get(vdr_id(), 0, "range_key")

        assert expected == redis_val
        assert expected == ts_val
      end
    end

    test "SETRANGE on empty key replicates correctly", %{redis: redis} do
      # SETRANGE on empty key pads with zero bytes
      Redix.command!(redis, ["SETRANGE", "empty_range", "5", "Hi"])

      assert_within 1000 do
        expected = <<0, 0, 0, 0, 0, "Hi"::binary>>
        redis_val = Redix.command!(redis, ["GET", "empty_range"])
        ts_val = Veidrodelis.get(vdr_id(), 0, "empty_range")

        assert expected == redis_val
        assert expected == ts_val
      end
    end

    # NOTE: Commands like INCR, INCRBY, INCRBYFLOAT, DECR, DECRBY, GETSET, SETNX, and MSETNX
    # are not replicated as-is. Redis converts them to SET/MSET commands in the replication stream.
    # Therefore, they are already tested by the SET and MSET tests above.
    # We don't need separate tests for these commands.

    test "INCR replicates as SET", %{redis: redis} do
      Redix.command!(redis, ["SET", "counter", "10"])
      Redix.command!(redis, ["INCR", "counter"])

      assert_within 1000 do
        expected = "11"
        redis_val = Redix.command!(redis, ["GET", "counter"])
        ts_val = Veidrodelis.get(vdr_id(), 0, "counter")

        assert expected == redis_val
        assert expected == ts_val
      end
    end

    test "INCR on empty key replicates correctly", %{redis: redis} do
      # INCR on non-existing key treats it as 0
      Redix.command!(redis, ["INCR", "new_counter"])

      assert_within 1000 do
        expected = "1"
        redis_val = Redix.command!(redis, ["GET", "new_counter"])
        ts_val = Veidrodelis.get(vdr_id(), 0, "new_counter")

        assert expected == redis_val
        assert expected == ts_val
      end
    end

    test "INCRBY replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["SET", "incrby_key", "100"])
      Redix.command!(redis, ["INCRBY", "incrby_key", "42"])

      assert_within 1000 do
        expected = "142"
        redis_val = Redix.command!(redis, ["GET", "incrby_key"])
        ts_val = Veidrodelis.get(vdr_id(), 0, "incrby_key")

        assert expected == redis_val
        assert expected == ts_val
      end
    end

    test "INCRBYFLOAT replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["SET", "float_key", "10.5"])
      Redix.command!(redis, ["INCRBYFLOAT", "float_key", "2.3"])

      assert_within 1000 do
        expected = "12.8"
        redis_val = Redix.command!(redis, ["GET", "float_key"])
        ts_val = Veidrodelis.get(vdr_id(), 0, "float_key")

        assert expected == redis_val
        assert expected == ts_val
      end
    end

    test "DECR replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["SET", "decr_key", "10"])
      Redix.command!(redis, ["DECR", "decr_key"])

      assert_within 1000 do
        expected = "9"
        redis_val = Redix.command!(redis, ["GET", "decr_key"])
        ts_val = Veidrodelis.get(vdr_id(), 0, "decr_key")

        assert expected == redis_val
        assert expected == ts_val
      end
    end

    test "DECRBY replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["SET", "decrby_key", "100"])
      Redix.command!(redis, ["DECRBY", "decrby_key", "30"])

      assert_within 1000 do
        expected = "70"
        redis_val = Redix.command!(redis, ["GET", "decrby_key"])
        ts_val = Veidrodelis.get(vdr_id(), 0, "decrby_key")

        assert expected == redis_val
        assert expected == ts_val
      end
    end

    test "GETSET replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["SET", "getset_key", "old_value"])
      Redix.command!(redis, ["GETSET", "getset_key", "new_value"])

      assert_within 1000 do
        expected = "new_value"
        redis_val = Redix.command!(redis, ["GET", "getset_key"])
        ts_val = Veidrodelis.get(vdr_id(), 0, "getset_key")

        assert expected == redis_val
        assert expected == ts_val
      end
    end

    test "SETNX when key does not exist replicates correctly", %{redis: redis} do
      result = Redix.command!(redis, ["SETNX", "setnx_key", "setnx_value"])

      assert_within 1000 do
        expected = "setnx_value"
        redis_val = Redix.command!(redis, ["GET", "setnx_key"])
        ts_val = Veidrodelis.get(vdr_id(), 0, "setnx_key")

        assert expected == redis_val
        assert expected == ts_val
        assert 1 == result
      end
    end

    test "SETNX when key exists does not replicate", %{redis: redis} do
      Redix.command!(redis, ["SET", "existing_key", "original"])
      result = Redix.command!(redis, ["SETNX", "existing_key", "new_value"])

      assert_within 1000 do
        expected = "original"
        redis_val = Redix.command!(redis, ["GET", "existing_key"])
        ts_val = Veidrodelis.get(vdr_id(), 0, "existing_key")

        assert expected == redis_val
        assert expected == ts_val
        assert 0 == result
      end
    end

    test "MSETNX when no keys exist replicates correctly", %{redis: redis} do
      result = Redix.command!(redis, ["MSETNX", "msetnx1", "val1", "msetnx2", "val2"])

      assert_within 1000 do
        redis_val1 = Redix.command!(redis, ["GET", "msetnx1"])
        redis_val2 = Redix.command!(redis, ["GET", "msetnx2"])
        ts_val1 = Veidrodelis.get(vdr_id(), 0, "msetnx1")
        ts_val2 = Veidrodelis.get(vdr_id(), 0, "msetnx2")

        assert "val1" == redis_val1
        assert "val1" == ts_val1
        assert "val2" == redis_val2
        assert "val2" == ts_val2
        assert 1 == result
      end
    end

    test "MSETNX when a key exists does not replicate", %{redis: redis} do
      Redix.command!(redis, ["SET", "existing_msetnx", "exists"])
      result = Redix.command!(redis, ["MSETNX", "existing_msetnx", "new", "msetnx_new", "val"])

      assert_within 1000 do
        redis_val1 = Redix.command!(redis, ["GET", "existing_msetnx"])
        redis_val2 = Redix.command!(redis, ["GET", "msetnx_new"])
        ts_val1 = Veidrodelis.get(vdr_id(), 0, "existing_msetnx")
        ts_val2 = Veidrodelis.get(vdr_id(), 0, "msetnx_new")

        assert "exists" == redis_val1
        assert "exists" == ts_val1
        assert nil == redis_val2
        assert nil == ts_val2
        assert 0 == result
      end
    end
  end
end
