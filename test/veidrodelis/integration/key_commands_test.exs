defmodule Veidrodelis.Integration.KeyCommandsTest do
  @moduledoc """
  Integration tests for key iteration commands.
  """

  use ExUnit.Case, async: false
  use CommandMatchers
  use IntegrationHelpers
  require Logger

  setup do
    setup_redis()
  end

  describe "key navigation helpers" do
    @describetag timeout: 30_000

    setup %{redis: redis} do
      setup_veidrodelis(redis)
    end

    test "first/last/next/prev work correctly", %{redis: redis} do
      # Create keys in Redis (they will be replicated)
      Redix.command!(redis, ["SET", "key_alpha", "1"])
      Redix.command!(redis, ["SET", "key_beta", "2"])
      Redix.command!(redis, ["SET", "key_gamma", "3"])

      assert_within 1000 do
        assert {:ok, ["key_alpha"]} == Veidrodelis.first(vdr_id(), 0, 1)
        assert {:ok, ["key_gamma"]} == Veidrodelis.last(vdr_id(), 0, 1)
      end

      assert {:ok, ["key_beta"]} == Veidrodelis.next(vdr_id(), 0, "key_alpha", 1)
      assert {:ok, ["key_beta"]} == Veidrodelis.prev(vdr_id(), 0, "key_gamma", 1)
    end

    test "read_tx accepts key navigation commands", %{redis: redis} do
      Redix.command!(redis, ["SET", "key_alpha", "1"])
      Redix.command!(redis, ["SET", "key_beta", "2"])
      Redix.command!(redis, ["SET", "key_gamma", "3"])

      assert_within 1000 do
        assert {:ok,
                [
                  {:ok, ["key_alpha"]},
                  {:ok, ["key_gamma"]},
                  {:ok, ["key_beta"]},
                  {:ok, ["key_beta"]},
                  {:ok, []},
                  {:ok, []}
                ]} =
                 Veidrodelis.read_tx(vdr_id(), 0, [
                   {:first, 1},
                   {:last, 1},
                   {:next, "key_alpha", 1},
                   {:prev, "key_gamma", 1},
                   {:next, "key_gamma", 1},
                   {:prev, "key_alpha", 1}
                 ])
      end
    end

    test "next/prev work with concrete counts", %{redis: redis} do
      keys = ["k01", "k02", "k03", "k04"]

      for key <- keys do
        Redix.command!(redis, ["SET", key, "value"])
      end

      assert_within 1000 do
        assert {:ok, 4} ==
                 Veidrodelis.first(vdr_id(), 0, 10) |> elem(1) |> length() |> then(&{:ok, &1})
      end

      assert {:ok, []} == Veidrodelis.next(vdr_id(), 0, "k04", 0)
      assert {:ok, ["k04"]} == Veidrodelis.next(vdr_id(), 0, "k03", 1)
      assert {:ok, ["k03", "k04"]} == Veidrodelis.next(vdr_id(), 0, "k02", 2)
      assert {:ok, ["k01", "k02", "k03", "k04"]} == Veidrodelis.next(vdr_id(), 0, "k00", 4)

      assert {:ok, []} == Veidrodelis.prev(vdr_id(), 0, "k01", 0)
      assert {:ok, ["k01"]} == Veidrodelis.prev(vdr_id(), 0, "k02", 1)
      assert {:ok, ["k02", "k01"]} == Veidrodelis.prev(vdr_id(), 0, "k03", 2)
      assert {:ok, ["k04", "k03", "k02", "k01"]} == Veidrodelis.prev(vdr_id(), 0, "k05", 4)

      assert {:ok, [{:ok, ["k03", "k04"]}, {:ok, ["k02", "k01"]}]} =
               Veidrodelis.read_tx(vdr_id(), 0, [
                 {:next, "k02", 2},
                 {:prev, "k03", 2}
               ])

      assert {:ok, []} == Veidrodelis.next(vdr_id(), 0, "k04", 1)
      assert {:ok, ["k04"]} == Veidrodelis.next(vdr_id(), 0, "k03", 1)
      assert {:ok, []} == Veidrodelis.prev(vdr_id(), 0, "k01", 1)
      assert {:ok, ["k01"]} == Veidrodelis.prev(vdr_id(), 0, "k02", 1)
    end

    test "first/last with various counts", %{redis: redis} do
      keys = ["k01", "k02", "k03", "k04"]

      for key <- keys do
        Redix.command!(redis, ["SET", key, "value"])
      end

      assert_within 1000 do
        assert {:ok, 4} ==
                 Veidrodelis.first(vdr_id(), 0, 10) |> elem(1) |> length() |> then(&{:ok, &1})
      end

      assert {:ok, []} == Veidrodelis.first(vdr_id(), 0, 0)
      assert {:ok, ["k01"]} == Veidrodelis.first(vdr_id(), 0, 1)
      assert {:ok, ["k01", "k02"]} == Veidrodelis.first(vdr_id(), 0, 2)
      assert {:ok, ["k01", "k02", "k03", "k04"]} == Veidrodelis.first(vdr_id(), 0, 4)

      assert {:ok, []} == Veidrodelis.last(vdr_id(), 0, 0)
      assert {:ok, ["k04"]} == Veidrodelis.last(vdr_id(), 0, 1)
      assert {:ok, ["k04", "k03"]} == Veidrodelis.last(vdr_id(), 0, 2)
      assert {:ok, ["k04", "k03", "k02", "k01"]} == Veidrodelis.last(vdr_id(), 0, 4)

      assert {:ok, [{:ok, ["k01", "k02"]}, {:ok, ["k04", "k03"]}]} =
               Veidrodelis.read_tx(vdr_id(), 0, [
                 {:first, 2},
                 {:last, 2}
               ])
    end

    test "returns empty for non-existent db", %{redis: _redis} do
      # db 7 should be empty
      assert {:ok, []} == Veidrodelis.first(vdr_id(), 7, 1)
      assert {:ok, []} == Veidrodelis.last(vdr_id(), 7, 1)
      assert {:ok, []} == Veidrodelis.next(vdr_id(), 7, "foo", 1)
      assert {:ok, []} == Veidrodelis.prev(vdr_id(), 7, "foo", 1)
    end
  end
end
