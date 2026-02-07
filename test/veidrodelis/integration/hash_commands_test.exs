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
  end
end
