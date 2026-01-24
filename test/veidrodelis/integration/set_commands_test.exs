defmodule Veidrodelis.Integration.SetCommandsTest do
  @moduledoc """
  Integration tests for set commands.

  Triple comparison tests: verify that Redis value, TS value, and expected value are all equal.
  Includes comprehensive edge case tests for SREM, SMOVE, SUNIONSTORE, SINTERSTORE, SDIFFSTORE, and SISMEMBER.
  """

  use ExUnit.Case, async: false
  use CommandMatchers
  use IntegrationHelpers
  require Logger

  setup do
    setup_redis()
  end

  describe "set commands" do
    @describetag timeout: 30_000

    setup %{redis: redis} do
      setup_veidrodelis(redis)
    end

    test "SREM removes single member from set", %{redis: redis} do
      Redix.command!(redis, ["SADD", "srem_single", "a", "b", "c"])
      Redix.command!(redis, ["SREM", "srem_single", "b"])

      assert_within 1000 do
        expected_card = 2
        expected_members = ["a", "c"]
        redis_card = Redix.command!(redis, ["SCARD", "srem_single"])
        {:ok, ts_card} = Veidrodelis.scard(vdr_id(), 0, "srem_single")
        redis_members = Redix.command!(redis, ["SMEMBERS", "srem_single"]) |> Enum.sort()
        {:ok, ts_members_tmp} = Veidrodelis.smembers(vdr_id(), 0, "srem_single")
        ts_members = Enum.sort(ts_members_tmp)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "SREM removes multiple members from set", %{redis: redis} do
      Redix.command!(redis, ["SADD", "srem_multi", "a", "b", "c", "d", "e"])
      Redix.command!(redis, ["SREM", "srem_multi", "b", "d"])

      assert_within 1000 do
        expected_card = 3
        expected_members = ["a", "c", "e"]
        redis_card = Redix.command!(redis, ["SCARD", "srem_multi"])
        {:ok, ts_card} = Veidrodelis.scard(vdr_id(), 0, "srem_multi")
        redis_members = Redix.command!(redis, ["SMEMBERS", "srem_multi"]) |> Enum.sort()
        {:ok, ts_members_tmp} = Veidrodelis.smembers(vdr_id(), 0, "srem_multi")
        ts_members = Enum.sort(ts_members_tmp)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "SREM on non-existent member does nothing", %{redis: redis} do
      Redix.command!(redis, ["SADD", "srem_nonexist", "a", "b", "c"])
      Redix.command!(redis, ["SREM", "srem_nonexist", "z"])

      assert_within 1000 do
        expected_card = 3
        redis_card = Redix.command!(redis, ["SCARD", "srem_nonexist"])
        {:ok, ts_card} = Veidrodelis.scard(vdr_id(), 0, "srem_nonexist")

        assert expected_card == redis_card
        assert expected_card == ts_card
      end
    end

    test "SREM on non-existent key does nothing", %{redis: redis} do
      Redix.command!(redis, ["SREM", "srem_nokey", "a"])

      assert_within 1000 do
        expected_card = 0
        redis_card = Redix.command!(redis, ["SCARD", "srem_nokey"])
        {:ok, ts_card} = Veidrodelis.scard(vdr_id(), 0, "srem_nokey")

        assert expected_card == redis_card
        assert expected_card == ts_card
      end
    end

    test "SREM removes all members leaves empty set", %{redis: redis} do
      Redix.command!(redis, ["SADD", "srem_all", "a", "b"])
      Redix.command!(redis, ["SREM", "srem_all", "a", "b"])

      assert_within 1000 do
        expected_card = 0
        redis_card = Redix.command!(redis, ["SCARD", "srem_all"])
        {:ok, ts_card} = Veidrodelis.scard(vdr_id(), 0, "srem_all")

        assert expected_card == redis_card
        assert expected_card == ts_card
      end
    end

    test "SMOVE moves member between sets", %{redis: redis} do
      Redix.command!(redis, ["SADD", "smove_src", "a", "b", "c"])
      Redix.command!(redis, ["SADD", "smove_dst", "x", "y"])
      Redix.command!(redis, ["SMOVE", "smove_src", "smove_dst", "b"])

      assert_within 1000 do
        expected_src = ["a", "c"]
        expected_dst = ["b", "x", "y"]
        redis_src = Redix.command!(redis, ["SMEMBERS", "smove_src"]) |> Enum.sort()
        {:ok, ts_src_tmp} = Veidrodelis.smembers(vdr_id(), 0, "smove_src")
        ts_src = Enum.sort(ts_src_tmp)
        redis_dst = Redix.command!(redis, ["SMEMBERS", "smove_dst"]) |> Enum.sort()
        {:ok, ts_dst_tmp} = Veidrodelis.smembers(vdr_id(), 0, "smove_dst")
        ts_dst = Enum.sort(ts_dst_tmp)

        assert expected_src == redis_src
        assert expected_src == ts_src
        assert expected_dst == redis_dst
        assert expected_dst == ts_dst
      end
    end

    test "SMOVE to non-existent destination creates it", %{redis: redis} do
      Redix.command!(redis, ["SADD", "smove_src2", "a", "b"])
      Redix.command!(redis, ["SMOVE", "smove_src2", "smove_dst2", "a"])

      assert_within 1000 do
        expected_src = ["b"]
        expected_dst = ["a"]
        redis_src = Redix.command!(redis, ["SMEMBERS", "smove_src2"]) |> Enum.sort()
        {:ok, ts_src_tmp} = Veidrodelis.smembers(vdr_id(), 0, "smove_src2")
        ts_src = Enum.sort(ts_src_tmp)
        redis_dst = Redix.command!(redis, ["SMEMBERS", "smove_dst2"]) |> Enum.sort()
        {:ok, ts_dst_tmp} = Veidrodelis.smembers(vdr_id(), 0, "smove_dst2")
        ts_dst = Enum.sort(ts_dst_tmp)

        assert expected_src == redis_src
        assert expected_src == ts_src
        assert expected_dst == redis_dst
        assert expected_dst == ts_dst
      end
    end

    test "SMOVE non-existent member does nothing", %{redis: redis} do
      Redix.command!(redis, ["SADD", "smove_src3", "a", "b"])
      Redix.command!(redis, ["SADD", "smove_dst3", "x"])
      Redix.command!(redis, ["SMOVE", "smove_src3", "smove_dst3", "z"])

      assert_within 1000 do
        expected_src = ["a", "b"]
        expected_dst = ["x"]
        redis_src = Redix.command!(redis, ["SMEMBERS", "smove_src3"]) |> Enum.sort()
        {:ok, ts_src_tmp} = Veidrodelis.smembers(vdr_id(), 0, "smove_src3")
        ts_src = Enum.sort(ts_src_tmp)
        redis_dst = Redix.command!(redis, ["SMEMBERS", "smove_dst3"]) |> Enum.sort()
        {:ok, ts_dst_tmp} = Veidrodelis.smembers(vdr_id(), 0, "smove_dst3")
        ts_dst = Enum.sort(ts_dst_tmp)

        assert expected_src == redis_src
        assert expected_src == ts_src
        assert expected_dst == redis_dst
        assert expected_dst == ts_dst
      end
    end

    test "SUNIONSTORE creates union of two sets", %{redis: redis} do
      Redix.command!(redis, ["SADD", "union_a", "1", "2", "3"])
      Redix.command!(redis, ["SADD", "union_b", "2", "3", "4"])
      Redix.command!(redis, ["SUNIONSTORE", "union_result", "union_a", "union_b"])

      assert_within 1000 do
        expected_members = ["1", "2", "3", "4"]
        expected_card = 4
        redis_card = Redix.command!(redis, ["SCARD", "union_result"])
        {:ok, ts_card} = Veidrodelis.scard(vdr_id(), 0, "union_result")
        redis_members = Redix.command!(redis, ["SMEMBERS", "union_result"]) |> Enum.sort()
        {:ok, ts_members_tmp} = Veidrodelis.smembers(vdr_id(), 0, "union_result")
        ts_members = Enum.sort(ts_members_tmp)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "SUNIONSTORE with multiple source sets", %{redis: redis} do
      Redix.command!(redis, ["SADD", "union_m1", "a", "b"])
      Redix.command!(redis, ["SADD", "union_m2", "b", "c"])
      Redix.command!(redis, ["SADD", "union_m3", "c", "d"])
      Redix.command!(redis, ["SUNIONSTORE", "union_multi", "union_m1", "union_m2", "union_m3"])

      assert_within 1000 do
        expected_members = ["a", "b", "c", "d"]
        expected_card = 4
        redis_card = Redix.command!(redis, ["SCARD", "union_multi"])
        {:ok, ts_card} = Veidrodelis.scard(vdr_id(), 0, "union_multi")
        redis_members = Redix.command!(redis, ["SMEMBERS", "union_multi"]) |> Enum.sort()
        {:ok, ts_members_tmp} = Veidrodelis.smembers(vdr_id(), 0, "union_multi")
        ts_members = Enum.sort(ts_members_tmp)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "SUNIONSTORE overwrites existing destination", %{redis: redis} do
      Redix.command!(redis, ["SADD", "union_src1", "a", "b"])
      Redix.command!(redis, ["SADD", "union_src2", "b", "c"])
      Redix.command!(redis, ["SADD", "union_overwrite", "old1", "old2"])
      Redix.command!(redis, ["SUNIONSTORE", "union_overwrite", "union_src1", "union_src2"])

      assert_within 1000 do
        expected_members = ["a", "b", "c"]
        redis_members = Redix.command!(redis, ["SMEMBERS", "union_overwrite"]) |> Enum.sort()
        {:ok, ts_members_tmp} = Veidrodelis.smembers(vdr_id(), 0, "union_overwrite")
        ts_members = Enum.sort(ts_members_tmp)

        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "SINTERSTORE creates intersection of two sets", %{redis: redis} do
      Redix.command!(redis, ["SADD", "inter_a", "1", "2", "3"])
      Redix.command!(redis, ["SADD", "inter_b", "2", "3", "4"])
      Redix.command!(redis, ["SINTERSTORE", "inter_result", "inter_a", "inter_b"])

      assert_within 1000 do
        expected_members = ["2", "3"]
        expected_card = 2
        redis_card = Redix.command!(redis, ["SCARD", "inter_result"])
        {:ok, ts_card} = Veidrodelis.scard(vdr_id(), 0, "inter_result")
        redis_members = Redix.command!(redis, ["SMEMBERS", "inter_result"]) |> Enum.sort()
        {:ok, ts_members_tmp} = Veidrodelis.smembers(vdr_id(), 0, "inter_result")
        ts_members = Enum.sort(ts_members_tmp)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "SINTERSTORE with multiple source sets", %{redis: redis} do
      Redix.command!(redis, ["SADD", "inter_m1", "a", "b", "c", "d"])
      Redix.command!(redis, ["SADD", "inter_m2", "b", "c", "d", "e"])
      Redix.command!(redis, ["SADD", "inter_m3", "c", "d", "e", "f"])
      Redix.command!(redis, ["SINTERSTORE", "inter_multi", "inter_m1", "inter_m2", "inter_m3"])

      assert_within 1000 do
        expected_members = ["c", "d"]
        expected_card = 2
        redis_card = Redix.command!(redis, ["SCARD", "inter_multi"])
        {:ok, ts_card} = Veidrodelis.scard(vdr_id(), 0, "inter_multi")
        redis_members = Redix.command!(redis, ["SMEMBERS", "inter_multi"]) |> Enum.sort()
        {:ok, ts_members_tmp} = Veidrodelis.smembers(vdr_id(), 0, "inter_multi")
        ts_members = Enum.sort(ts_members_tmp)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "SINTERSTORE with no overlap creates empty set", %{redis: redis} do
      Redix.command!(redis, ["SADD", "inter_disjoint1", "a", "b"])
      Redix.command!(redis, ["SADD", "inter_disjoint2", "c", "d"])
      Redix.command!(redis, ["SINTERSTORE", "inter_empty", "inter_disjoint1", "inter_disjoint2"])

      assert_within 1000 do
        expected_card = 0
        redis_card = Redix.command!(redis, ["SCARD", "inter_empty"])
        {:ok, ts_card} = Veidrodelis.scard(vdr_id(), 0, "inter_empty")

        assert expected_card == redis_card
        assert expected_card == ts_card
      end
    end

    test "SINTERSTORE overwrites existing destination", %{redis: redis} do
      Redix.command!(redis, ["SADD", "inter_src1", "a", "b", "c"])
      Redix.command!(redis, ["SADD", "inter_src2", "b", "c", "d"])
      Redix.command!(redis, ["SADD", "inter_overwrite", "old1", "old2"])
      Redix.command!(redis, ["SINTERSTORE", "inter_overwrite", "inter_src1", "inter_src2"])

      assert_within 1000 do
        expected_members = ["b", "c"]
        redis_members = Redix.command!(redis, ["SMEMBERS", "inter_overwrite"]) |> Enum.sort()
        {:ok, ts_members_tmp} = Veidrodelis.smembers(vdr_id(), 0, "inter_overwrite")
        ts_members = Enum.sort(ts_members_tmp)

        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "SDIFFSTORE creates difference of two sets", %{redis: redis} do
      Redix.command!(redis, ["SADD", "diff_a", "1", "2", "3", "4"])
      Redix.command!(redis, ["SADD", "diff_b", "2", "3"])
      Redix.command!(redis, ["SDIFFSTORE", "diff_result", "diff_a", "diff_b"])

      assert_within 1000 do
        expected_members = ["1", "4"]
        expected_card = 2
        redis_card = Redix.command!(redis, ["SCARD", "diff_result"])
        {:ok, ts_card} = Veidrodelis.scard(vdr_id(), 0, "diff_result")
        redis_members = Redix.command!(redis, ["SMEMBERS", "diff_result"]) |> Enum.sort()
        {:ok, ts_members_tmp} = Veidrodelis.smembers(vdr_id(), 0, "diff_result")
        ts_members = Enum.sort(ts_members_tmp)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "SDIFFSTORE with multiple source sets", %{redis: redis} do
      Redix.command!(redis, ["SADD", "diff_m1", "a", "b", "c", "d", "e"])
      Redix.command!(redis, ["SADD", "diff_m2", "b", "c"])
      Redix.command!(redis, ["SADD", "diff_m3", "d"])
      Redix.command!(redis, ["SDIFFSTORE", "diff_multi", "diff_m1", "diff_m2", "diff_m3"])

      assert_within 1000 do
        expected_members = ["a", "e"]
        expected_card = 2
        redis_card = Redix.command!(redis, ["SCARD", "diff_multi"])
        {:ok, ts_card} = Veidrodelis.scard(vdr_id(), 0, "diff_multi")
        redis_members = Redix.command!(redis, ["SMEMBERS", "diff_multi"]) |> Enum.sort()
        {:ok, ts_members_tmp} = Veidrodelis.smembers(vdr_id(), 0, "diff_multi")
        ts_members = Enum.sort(ts_members_tmp)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "SDIFFSTORE with total overlap creates empty set", %{redis: redis} do
      Redix.command!(redis, ["SADD", "diff_same1", "a", "b", "c"])
      Redix.command!(redis, ["SADD", "diff_same2", "a", "b", "c"])
      Redix.command!(redis, ["SDIFFSTORE", "diff_empty", "diff_same1", "diff_same2"])

      assert_within 1000 do
        expected_card = 0
        redis_card = Redix.command!(redis, ["SCARD", "diff_empty"])
        {:ok, ts_card} = Veidrodelis.scard(vdr_id(), 0, "diff_empty")

        assert expected_card == redis_card
        assert expected_card == ts_card
      end
    end

    test "SDIFFSTORE overwrites existing destination", %{redis: redis} do
      Redix.command!(redis, ["SADD", "diff_src1", "a", "b", "c"])
      Redix.command!(redis, ["SADD", "diff_src2", "c"])
      Redix.command!(redis, ["SADD", "diff_overwrite", "old1", "old2"])
      Redix.command!(redis, ["SDIFFSTORE", "diff_overwrite", "diff_src1", "diff_src2"])

      assert_within 1000 do
        expected_members = ["a", "b"]
        redis_members = Redix.command!(redis, ["SMEMBERS", "diff_overwrite"]) |> Enum.sort()
        {:ok, ts_members_tmp} = Veidrodelis.smembers(vdr_id(), 0, "diff_overwrite")
        ts_members = Enum.sort(ts_members_tmp)

        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "SISMEMBER returns true for existing member", %{redis: redis} do
      Redix.command!(redis, ["SADD", "sismember_test", "a", "b", "c"])

      assert_within 1000 do
        redis_is_member = Redix.command!(redis, ["SISMEMBER", "sismember_test", "b"])
        {:ok, ts_is_member} = Veidrodelis.sismember(vdr_id(), 0, "sismember_test", "b")

        assert 1 == redis_is_member
        assert true == ts_is_member
      end
    end

    test "SISMEMBER returns false for non-existent member", %{redis: redis} do
      Redix.command!(redis, ["SADD", "sismember_test2", "a", "b", "c"])

      assert_within 1000 do
        redis_is_member = Redix.command!(redis, ["SISMEMBER", "sismember_test2", "z"])
        {:ok, ts_is_member} = Veidrodelis.sismember(vdr_id(), 0, "sismember_test2", "z")

        assert 0 == redis_is_member
        assert false == ts_is_member
      end
    end

    test "SISMEMBER returns false for non-existent key", %{redis: redis} do
      assert_within 1000 do
        redis_is_member = Redix.command!(redis, ["SISMEMBER", "sismember_nokey", "a"])
        {:ok, ts_is_member} = Veidrodelis.sismember(vdr_id(), 0, "sismember_nokey", "a")

        assert 0 == redis_is_member
        assert false == ts_is_member
      end
    end

    test "SISMEMBER after SREM", %{redis: redis} do
      Redix.command!(redis, ["SADD", "sismember_srem", "a", "b", "c"])
      Redix.command!(redis, ["SREM", "sismember_srem", "b"])

      assert_within 1000 do
        redis_is_member = Redix.command!(redis, ["SISMEMBER", "sismember_srem", "b"])
        {:ok, ts_is_member} = Veidrodelis.sismember(vdr_id(), 0, "sismember_srem", "b")

        assert 0 == redis_is_member
        assert false == ts_is_member
      end
    end

    test "SISMEMBER after SMOVE", %{redis: redis} do
      Redix.command!(redis, ["SADD", "sismember_smove_src", "a", "b"])
      Redix.command!(redis, ["SADD", "sismember_smove_dst", "x"])
      Redix.command!(redis, ["SMOVE", "sismember_smove_src", "sismember_smove_dst", "b"])

      assert_within 1000 do
        redis_is_member_src = Redix.command!(redis, ["SISMEMBER", "sismember_smove_src", "b"])
        {:ok, ts_is_member_src} = Veidrodelis.sismember(vdr_id(), 0, "sismember_smove_src", "b")
        redis_is_member_dst = Redix.command!(redis, ["SISMEMBER", "sismember_smove_dst", "b"])
        {:ok, ts_is_member_dst} = Veidrodelis.sismember(vdr_id(), 0, "sismember_smove_dst", "b")

        assert 0 == redis_is_member_src
        assert false == ts_is_member_src
        assert 1 == redis_is_member_dst
        assert true == ts_is_member_dst
      end
    end
  end
end
