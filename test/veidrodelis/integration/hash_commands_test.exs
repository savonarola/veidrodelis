defmodule Veidrodelis.Integration.HashCommandsTest do
  @moduledoc """
  Integration coverage for hash navigation helpers exposed through Veidrodelis and read_tx.
  """

  use ExUnit.Case, async: false
  use CommandMatchers
  use IntegrationHelpers
  require Logger

  setup do
    setup_redis()
  end

  describe "hash navigation helpers in Veidrodelis" do
    @describetag timeout: 30_000

    setup %{redis: redis} do
      setup_veidrodelis(redis)
    end

    test "hfirst/hlast/hnext/hprev replicate correctly", %{redis: redis} do
      key = "integration_hash_nav_#{:erlang.unique_integer([:positive])}"
      Redix.command!(redis, ["HSET", key, "a", "1", "b", "2", "c", "3"])

      assert_within 1000 do
        assert {:ok, {"a", "1"}} == Veidrodelis.hfirst(vdr_id(), 0, key)
        assert {:ok, {"c", "3"}} == Veidrodelis.hlast(vdr_id(), 0, key)
      end

      assert {:ok, {"b", "2"}} == Veidrodelis.hnext(vdr_id(), 0, key, "a")
      assert {:ok, {"b", "2"}} == Veidrodelis.hprev(vdr_id(), 0, key, "c")
    end

    test "read_tx supports hash navigation commands", %{redis: redis} do
      key = "integration_hash_nav_tx_#{:erlang.unique_integer([:positive])}"
      Redix.command!(redis, ["HSET", key, "a", "1", "b", "2", "c", "3"])

      assert_within 1000 do
        assert {:ok, [from_first, from_last | _]} =
                 Veidrodelis.read_tx(vdr_id(), 0, [
                   {:hfirst, key},
                   {:hlast, key}
                 ])

        assert from_first == {:ok, {"a", "1"}}
        assert from_last == {:ok, {"c", "3"}}
      end

      assert {:ok,
              [
                {:ok, {"a", "1"}},
                {:ok, {"c", "3"}},
                {:ok, {"b", "2"}},
                {:ok, {"b", "2"}},
                {:ok, nil},
                {:ok, nil}
              ]} =
               Veidrodelis.read_tx(vdr_id(), 0, [
                 {:hfirst, key},
                 {:hlast, key},
                 {:hnext, key, "a"},
                 {:hprev, key, "c"},
                 {:hnext, key, "c"},
                 {:hprev, key, "a"}
               ])
    end
  end

  describe "hash commands across Veidrodelis API" do
    @describetag timeout: 30_000

    setup %{redis: redis} do
      setup_veidrodelis(redis)
    end

    test "hash getters reflect Redis state", %{redis: redis} do
      key = "integration_hash_api_#{:erlang.unique_integer([:positive])}"
      Redix.command!(redis, ["HSET", key, "name", "Alice", "email", "alice@example.com"])

      assert_within 1000 do
        assert {:ok, "Alice"} == Veidrodelis.hget(vdr_id(), 0, key, "name")

        assert {:ok, ["Alice", "alice@example.com"]} ==
                 Veidrodelis.hmget(vdr_id(), 0, key, ["name", "email"])

        assert {:ok, [{"email", "alice@example.com"}, {"name", "Alice"}]} =
                 Veidrodelis.hgetall(vdr_id(), 0, key)

        assert {:ok, ["email", "name"]} == Veidrodelis.hkeys(vdr_id(), 0, key)
        assert {:ok, ["alice@example.com", "Alice"]} == Veidrodelis.hvals(vdr_id(), 0, key)
        assert {:ok, 2} == Veidrodelis.hlen(vdr_id(), 0, key)
      end
    end

    test "hash helpers include multivals and random sampler", %{redis: redis} do
      key = "integration_hash_misc_#{:erlang.unique_integer([:positive])}"
      Redix.command!(redis, ["HSET", key, "name", "Alice", "email", "alice@example.com"])

      assert_within 1000 do
        assert {:ok, true} == Veidrodelis.hexists(vdr_id(), 0, key, "name")
        assert {:ok, false} == Veidrodelis.hexists(vdr_id(), 0, key, "missing")

        assert {:ok, byte_size("alice@example.com")} ==
                 Veidrodelis.hstrlen(vdr_id(), 0, key, "email")

        assert {:ok, rand_fields} = Veidrodelis.hrandfield(vdr_id(), 0, key, 2, true)
        assert length(rand_fields) <= 2

        assert Enum.all?(rand_fields, fn {field, value} ->
                 field in ["name", "email"] and is_binary(value)
               end)

        assert {:ok, rand_fields_only} = Veidrodelis.hrandfield(vdr_id(), 0, key, 1, false)
        assert length(rand_fields_only) == 1

        assert {:ok, [{:ok, tx_rand}]} =
                 Veidrodelis.read_tx(vdr_id(), 0, [
                   {:hrandfield, key, 1, false}
                 ])

        assert length(tx_rand) == 1
      end
    end

    test "hash helpers return nil/empty when key missing", %{redis: _redis} do
      missing = "integration_hash_missing_#{:erlang.unique_integer([:positive])}"

      assert_within 1000 do
        assert {:ok, nil} == Veidrodelis.hget(vdr_id(), 0, missing, "field")
        assert {:ok, [nil]} == Veidrodelis.hmget(vdr_id(), 0, missing, ["field"])
        assert {:ok, []} == Veidrodelis.hgetall(vdr_id(), 0, missing)
        assert {:ok, []} == Veidrodelis.hkeys(vdr_id(), 0, missing)
        assert {:ok, []} == Veidrodelis.hvals(vdr_id(), 0, missing)
        assert {:ok, 0} == Veidrodelis.hlen(vdr_id(), 0, missing)
      end
    end

    test "HDEL removes fields correctly", %{redis: redis} do
      key = "integration_hdel_#{:erlang.unique_integer([:positive])}"
      Redix.command!(redis, ["HSET", key, "f1", "v1", "f2", "v2", "f3", "v3"])

      assert_within 1000 do
        assert {:ok, 3} == Veidrodelis.hlen(vdr_id(), 0, key)
      end

      # Delete a field
      Redix.command!(redis, ["HDEL", key, "f2"])

      assert_within 1000 do
        assert {:ok, 2} == Veidrodelis.hlen(vdr_id(), 0, key)
        assert {:ok, nil} == Veidrodelis.hget(vdr_id(), 0, key, "f2")
        assert {:ok, "v1"} == Veidrodelis.hget(vdr_id(), 0, key, "f1")
        assert {:ok, "v3"} == Veidrodelis.hget(vdr_id(), 0, key, "f3")
      end
    end

    test "HSET updates existing fields", %{redis: redis} do
      key = "integration_hset_update_#{:erlang.unique_integer([:positive])}"
      Redix.command!(redis, ["HSET", key, "field1", "original"])

      assert_within 1000 do
        assert {:ok, "original"} == Veidrodelis.hget(vdr_id(), 0, key, "field1")
      end

      # Update the field
      Redix.command!(redis, ["HSET", key, "field1", "updated"])

      assert_within 1000 do
        assert {:ok, "updated"} == Veidrodelis.hget(vdr_id(), 0, key, "field1")
      end
    end

    test "handles hash type mismatches", %{redis: redis} do
      # Create a string key
      Redix.command!(redis, ["SET", "mystring", "value"])

      assert_within 1000 do
        assert {:ok, "value"} == Veidrodelis.get(vdr_id(), 0, "mystring")

        # Trying to access string as hash should return error
        assert {:error, "WRONGTYPE: Operation against a key holding the wrong kind of value"} ==
                 Veidrodelis.hget(vdr_id(), 0, "mystring", "field")

        assert {:error, "WRONGTYPE: Operation against a key holding the wrong kind of value"} ==
                 Veidrodelis.hlen(vdr_id(), 0, "mystring")

        assert {:error, "WRONGTYPE: Operation against a key holding the wrong kind of value"} ==
                 Veidrodelis.hgetall(vdr_id(), 0, "mystring")
      end
    end
  end
end
