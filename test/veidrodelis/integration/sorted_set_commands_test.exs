defmodule Veidrodelis.Integration.SortedSetCommandsTest do
  @moduledoc """
  Integration tests for sorted set commands.

  Triple comparison tests: verify that Redis value, TS value, and expected value are all equal.
  Includes comprehensive edge case tests for ZADD options, ZINCRBY, ZREMRANGEBYSCORE, ZREMRANGEBYLEX, and set operations.
  """

  use ExUnit.Case, async: false
  use CommandMatchers
  use IntegrationHelpers
  require Logger

  setup do
    setup_redis()
  end

  describe "sorted set commands" do
    @describetag timeout: 30_000

    setup %{redis: redis} do
      setup_veidrodelis(redis)
    end

    test "ZPOPMAX replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "pop_test", "1", "a", "2", "b", "3", "c"])
      Redix.command!(redis, ["ZPOPMAX", "pop_test", "1"])

      assert_within 1000 do
        expected_card = 2
        redis_card = Redix.command!(redis, ["ZCARD", "pop_test"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "pop_test")

        assert expected_card == redis_card
        assert expected_card == ts_card
      end
    end

    test "ZPOPMIN replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "pop_test", "1", "a", "2", "b", "3", "c"])
      Redix.command!(redis, ["ZPOPMIN", "pop_test", "1"])

      assert_within 1000 do
        expected_card = 2
        redis_card = Redix.command!(redis, ["ZCARD", "pop_test"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "pop_test")

        assert expected_card == redis_card
        assert expected_card == ts_card
      end
    end

    test "ZREMRANGEBYRANK replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "rank_test", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZREMRANGEBYRANK", "rank_test", "1", "2"])

      assert_within 1000 do
        expected = ["a", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "rank_test", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "rank_test", 0, -1, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZREMRANGEBYSCORE replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "score_test", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZREMRANGEBYSCORE", "score_test", "2", "3"])

      assert_within 1000 do
        expected = ["a", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "score_test", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "score_test", 0, -1, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZUNIONSTORE replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zset_a", "1", "a", "2", "b"])
      Redix.command!(redis, ["ZADD", "zset_b", "2", "b", "3", "c"])
      Redix.command!(redis, ["ZUNIONSTORE", "zset_union", "2", "zset_a", "zset_b"])

      assert_within 1000 do
        expected_card = 3
        # 2.0 + 2.0
        expected_score_b = 4.0
        redis_card = Redix.command!(redis, ["ZCARD", "zset_union"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "zset_union")
        redis_score = Redix.command!(redis, ["ZSCORE", "zset_union", "b"])
        ts_score = Veidrodelis.zscore(vdr_id(), 0, "zset_union", "b")

        redis_score_float =
          case Float.parse(redis_score) do
            {f, _} -> f
            :error -> String.to_integer(redis_score) * 1.0
          end

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_score_b == redis_score_float
        assert expected_score_b == ts_score
      end
    end

    test "ZINTERSTORE replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zset_a", "1", "a", "2", "b"])
      Redix.command!(redis, ["ZADD", "zset_b", "2", "b", "3", "c"])
      Redix.command!(redis, ["ZINTERSTORE", "zset_inter", "2", "zset_a", "zset_b"])

      assert_within 1000 do
        expected_card = 1
        expected_members = ["b"]
        redis_card = Redix.command!(redis, ["ZCARD", "zset_inter"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "zset_inter")
        redis_members = Redix.command!(redis, ["ZRANGE", "zset_inter", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zset_inter", 0, -1, false)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "ZDIFFSTORE replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zdiff_a", "1", "a", "2", "b", "3", "c"])
      Redix.command!(redis, ["ZADD", "zdiff_b", "2", "b", "4", "d"])
      Redix.command!(redis, ["ZDIFFSTORE", "zdiff_result", "2", "zdiff_a", "zdiff_b"])

      assert_within 1000 do
        expected_card = 2
        expected_members = ["a", "c"]
        redis_card = Redix.command!(redis, ["ZCARD", "zdiff_result"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "zdiff_result")
        redis_members = Redix.command!(redis, ["ZRANGE", "zdiff_result", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zdiff_result", 0, -1, false)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "ZRANGESTORE by rank replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrangestore_src", "1", "a", "2", "b", "3", "c", "4", "d", "5", "e"])
      Redix.command!(redis, ["ZRANGESTORE", "zrangestore_dest", "zrangestore_src", "1", "3"])

      assert_within 1000 do
        expected_card = 3
        expected_members = ["b", "c", "d"]
        redis_card = Redix.command!(redis, ["ZCARD", "zrangestore_dest"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "zrangestore_dest")
        redis_members = Redix.command!(redis, ["ZRANGE", "zrangestore_dest", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zrangestore_dest", 0, -1, false)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "ZRANGESTORE with REV replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrangestore_rev_src", "1", "a", "2", "b", "3", "c", "4", "d", "5", "e"])
      Redix.command!(redis, ["ZRANGESTORE", "zrangestore_rev_dest", "zrangestore_rev_src", "1", "3", "REV"])

      assert_within 1000 do
        expected_card = 3
        # REV means we get rank 1-3 from the reversed order: d, c, b
        expected_members = ["b", "c", "d"]
        redis_card = Redix.command!(redis, ["ZCARD", "zrangestore_rev_dest"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "zrangestore_rev_dest")
        redis_members = Redix.command!(redis, ["ZRANGE", "zrangestore_rev_dest", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zrangestore_rev_dest", 0, -1, false)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "ZRANGESTORE BYSCORE replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrangestore_score_src", "1", "a", "2", "b", "3", "c", "4", "d", "5", "e"])
      Redix.command!(redis, ["ZRANGESTORE", "zrangestore_score_dest", "zrangestore_score_src", "2", "4", "BYSCORE"])

      assert_within 1000 do
        expected_card = 3
        expected_members = ["b", "c", "d"]
        redis_card = Redix.command!(redis, ["ZCARD", "zrangestore_score_dest"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "zrangestore_score_dest")
        redis_members = Redix.command!(redis, ["ZRANGE", "zrangestore_score_dest", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zrangestore_score_dest", 0, -1, false)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "ZRANGESTORE BYLEX replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrangestore_lex_src", "0", "a", "0", "b", "0", "c", "0", "d", "0", "e"])
      Redix.command!(redis, ["ZRANGESTORE", "zrangestore_lex_dest", "zrangestore_lex_src", "[b", "[d", "BYLEX"])

      assert_within 1000 do
        expected_card = 3
        expected_members = ["b", "c", "d"]
        redis_card = Redix.command!(redis, ["ZCARD", "zrangestore_lex_dest"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "zrangestore_lex_dest")
        redis_members = Redix.command!(redis, ["ZRANGE", "zrangestore_lex_dest", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zrangestore_lex_dest", 0, -1, false)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "ZRANGESTORE BYSCORE with LIMIT replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrangestore_limit_src", "1", "a", "2", "b", "3", "c", "4", "d", "5", "e"])
      # Redis requires LIMIT to be used with BYSCORE or BYLEX
      Redix.command!(redis, ["ZRANGESTORE", "zrangestore_limit_dest", "zrangestore_limit_src", "1", "5", "BYSCORE", "LIMIT", "1", "3"])

      assert_within 1000 do
        expected_card = 3
        # BYSCORE 1-5 gets all, LIMIT 1 3 means skip 1, take 3: b, c, d
        expected_members = ["b", "c", "d"]
        redis_card = Redix.command!(redis, ["ZCARD", "zrangestore_limit_dest"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "zrangestore_limit_dest")
        redis_members = Redix.command!(redis, ["ZRANGE", "zrangestore_limit_dest", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zrangestore_limit_dest", 0, -1, false)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "ZRANGESTORE BYSCORE with REV and LIMIT replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrangestore_complex_src", "1", "a", "2", "b", "3", "c", "4", "d", "5", "e", "6", "f"])
      Redix.command!(redis, ["ZRANGESTORE", "zrangestore_complex_dest", "zrangestore_complex_src", "2", "5", "BYSCORE", "REV", "LIMIT", "1", "2"])

      assert_within 1000 do
        # First verify Redis result to understand the behavior
        redis_card = Redix.command!(redis, ["ZCARD", "zrangestore_complex_dest"])
        redis_members = Redix.command!(redis, ["ZRANGE", "zrangestore_complex_dest", "0", "-1"])

        # Now verify TS matches Redis
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "zrangestore_complex_dest")
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zrangestore_complex_dest", 0, -1, false)

        assert redis_card == ts_card
        assert redis_members == ts_members
      end
    end

    # ===== ZRANGESTORE Edge Cases =====

    test "ZRANGESTORE BYRANK with negative indices", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zr_neg_src", "1", "a", "2", "b", "3", "c", "4", "d", "5", "e"])
      Redix.command!(redis, ["ZRANGESTORE", "zr_neg_dest", "zr_neg_src", "-3", "-1"])

      assert_within 1000 do
        expected_members = ["c", "d", "e"]
        redis_members = Redix.command!(redis, ["ZRANGE", "zr_neg_dest", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zr_neg_dest", 0, -1, false)

        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "ZRANGESTORE BYRANK with max greater than last element", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zr_maxgt_src", "1", "a", "2", "b", "3", "c"])
      Redix.command!(redis, ["ZRANGESTORE", "zr_maxgt_dest", "zr_maxgt_src", "1", "100"])

      assert_within 1000 do
        expected_members = ["b", "c"]
        redis_members = Redix.command!(redis, ["ZRANGE", "zr_maxgt_dest", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zr_maxgt_dest", 0, -1, false)

        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "ZRANGESTORE BYRANK with min greater than max", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zr_minmax_src", "1", "a", "2", "b", "3", "c"])
      Redix.command!(redis, ["ZRANGESTORE", "zr_minmax_dest", "zr_minmax_src", "3", "1"])

      assert_within 1000 do
        redis_card = Redix.command!(redis, ["ZCARD", "zr_minmax_dest"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "zr_minmax_dest")

        assert 0 == redis_card
        assert 0 == ts_card
      end
    end

    test "ZRANGESTORE BYRANK starting beyond last element", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zr_beyond_src", "1", "a", "2", "b", "3", "c"])
      Redix.command!(redis, ["ZRANGESTORE", "zr_beyond_dest", "zr_beyond_src", "10", "20"])

      assert_within 1000 do
        redis_card = Redix.command!(redis, ["ZCARD", "zr_beyond_dest"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "zr_beyond_dest")

        assert 0 == redis_card
        assert 0 == ts_card
      end
    end

    test "ZRANGESTORE BYSCORE with min less than first element", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zs_minlt_src", "10", "a", "20", "b", "30", "c"])
      Redix.command!(redis, ["ZRANGESTORE", "zs_minlt_dest", "zs_minlt_src", "-100", "15", "BYSCORE"])

      assert_within 1000 do
        expected_members = ["a"]
        redis_members = Redix.command!(redis, ["ZRANGE", "zs_minlt_dest", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zs_minlt_dest", 0, -1, false)

        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "ZRANGESTORE BYSCORE with max greater than last element", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zs_maxgt_src", "10", "a", "20", "b", "30", "c"])
      Redix.command!(redis, ["ZRANGESTORE", "zs_maxgt_dest", "zs_maxgt_src", "15", "1000", "BYSCORE"])

      assert_within 1000 do
        expected_members = ["b", "c"]
        redis_members = Redix.command!(redis, ["ZRANGE", "zs_maxgt_dest", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zs_maxgt_dest", 0, -1, false)

        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "ZRANGESTORE BYSCORE with min greater than max", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zs_minmax_src", "10", "a", "20", "b", "30", "c"])
      Redix.command!(redis, ["ZRANGESTORE", "zs_minmax_dest", "zs_minmax_src", "50", "10", "BYSCORE"])

      assert_within 1000 do
        redis_card = Redix.command!(redis, ["ZCARD", "zs_minmax_dest"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "zs_minmax_dest")

        assert 0 == redis_card
        assert 0 == ts_card
      end
    end

    test "ZRANGESTORE BYSCORE with LIMIT greater than available elements", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zs_limitgt_src", "10", "a", "20", "b", "30", "c"])
      Redix.command!(redis, ["ZRANGESTORE", "zs_limitgt_dest", "zs_limitgt_src", "10", "30", "BYSCORE", "LIMIT", "0", "100"])

      assert_within 1000 do
        expected_members = ["a", "b", "c"]
        redis_members = Redix.command!(redis, ["ZRANGE", "zs_limitgt_dest", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zs_limitgt_dest", 0, -1, false)

        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "ZRANGESTORE BYSCORE with -inf and +inf", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zs_inf_src", "10", "a", "20", "b", "30", "c"])
      Redix.command!(redis, ["ZRANGESTORE", "zs_inf_dest", "zs_inf_src", "-inf", "+inf", "BYSCORE"])

      assert_within 1000 do
        expected_members = ["a", "b", "c"]
        redis_members = Redix.command!(redis, ["ZRANGE", "zs_inf_dest", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zs_inf_dest", 0, -1, false)

        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "ZRANGESTORE BYLEX with min less than first element", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zl_minlt_src", "0", "b", "0", "d", "0", "f"])
      Redix.command!(redis, ["ZRANGESTORE", "zl_minlt_dest", "zl_minlt_src", "[a", "[c", "BYLEX"])

      assert_within 1000 do
        expected_members = ["b"]
        redis_members = Redix.command!(redis, ["ZRANGE", "zl_minlt_dest", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zl_minlt_dest", 0, -1, false)

        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "ZRANGESTORE BYLEX with max greater than last element", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zl_maxgt_src", "0", "b", "0", "d", "0", "f"])
      Redix.command!(redis, ["ZRANGESTORE", "zl_maxgt_dest", "zl_maxgt_src", "[d", "[z", "BYLEX"])

      assert_within 1000 do
        expected_members = ["d", "f"]
        redis_members = Redix.command!(redis, ["ZRANGE", "zl_maxgt_dest", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zl_maxgt_dest", 0, -1, false)

        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "ZRANGESTORE BYLEX with min greater than max", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zl_minmax_src", "0", "b", "0", "d", "0", "f"])
      Redix.command!(redis, ["ZRANGESTORE", "zl_minmax_dest", "zl_minmax_src", "[f", "[b", "BYLEX"])

      assert_within 1000 do
        redis_card = Redix.command!(redis, ["ZCARD", "zl_minmax_dest"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "zl_minmax_dest")

        assert 0 == redis_card
        assert 0 == ts_card
      end
    end

    test "ZRANGESTORE BYLEX with LIMIT greater than available elements", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zl_limitgt_src", "0", "b", "0", "d", "0", "f"])
      Redix.command!(redis, ["ZRANGESTORE", "zl_limitgt_dest", "zl_limitgt_src", "[b", "[f", "BYLEX", "LIMIT", "0", "100"])

      assert_within 1000 do
        expected_members = ["b", "d", "f"]
        redis_members = Redix.command!(redis, ["ZRANGE", "zl_limitgt_dest", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zl_limitgt_dest", 0, -1, false)

        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "ZRANGESTORE BYLEX with - and + bounds", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zl_unbounded_src", "0", "a", "0", "b", "0", "c"])
      Redix.command!(redis, ["ZRANGESTORE", "zl_unbounded_dest", "zl_unbounded_src", "-", "+", "BYLEX"])

      assert_within 1000 do
        expected_members = ["a", "b", "c"]
        redis_members = Redix.command!(redis, ["ZRANGE", "zl_unbounded_dest", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zl_unbounded_dest", 0, -1, false)

        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "ZMPOP replicates as ZPOPMAX", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zmpop_test", "1", "a", "2", "b", "3", "c"])
      Redix.command!(redis, ["ZMPOP", "1", "zmpop_test", "MAX", "COUNT", "2"])

      assert_within 1000 do
        expected_card = 1
        expected_members = ["a"]
        redis_card = Redix.command!(redis, ["ZCARD", "zmpop_test"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "zmpop_test")
        redis_members = Redix.command!(redis, ["ZRANGE", "zmpop_test", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "zmpop_test", 0, -1, false)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "BZMPOP replicates as ZPOPMIN", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "bzmpop_test", "1", "a", "2", "b", "3", "c"])
      Redix.command!(redis, ["BZMPOP", "0", "1", "bzmpop_test", "MIN", "COUNT", "2"])

      assert_within 1000 do
        expected_card = 1
        expected_members = ["c"]
        redis_card = Redix.command!(redis, ["ZCARD", "bzmpop_test"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "bzmpop_test")
        redis_members = Redix.command!(redis, ["ZRANGE", "bzmpop_test", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "bzmpop_test", 0, -1, false)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "BZPOPMAX replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "bzpopmax_test", "1", "a", "2", "b", "3", "c"])
      Redix.command!(redis, ["BZPOPMAX", "bzpopmax_test", "0"])

      assert_within 1000 do
        expected_card = 2
        expected_members = ["a", "b"]
        redis_card = Redix.command!(redis, ["ZCARD", "bzpopmax_test"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "bzpopmax_test")
        redis_members = Redix.command!(redis, ["ZRANGE", "bzpopmax_test", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "bzpopmax_test", 0, -1, false)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    test "BZPOPMIN replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "bzpopmin_test", "1", "a", "2", "b", "3", "c"])
      Redix.command!(redis, ["BZPOPMIN", "bzpopmin_test", "0"])

      assert_within 1000 do
        expected_card = 2
        expected_members = ["b", "c"]
        redis_card = Redix.command!(redis, ["ZCARD", "bzpopmin_test"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "bzpopmin_test")
        redis_members = Redix.command!(redis, ["ZRANGE", "bzpopmin_test", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "bzpopmin_test", 0, -1, false)

        assert expected_card == redis_card
        assert expected_card == ts_card
        assert expected_members == redis_members
        assert expected_members == ts_members
      end
    end

    # ===== Comprehensive Edge Case Tests =====

    test "ZADD with options: NX only adds new members", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "nx_test", "1", "existing"])
      Redix.command!(redis, ["ZADD", "nx_test", "NX", "2", "existing", "3", "new"])

      assert_within 1000 do
        assert {1.0, ""} == Float.parse(Redix.command!(redis, ["ZSCORE", "nx_test", "existing"]))
        assert 1.0 == Veidrodelis.zscore(vdr_id(), 0, "nx_test", "existing")
        assert {3.0, ""} == Float.parse(Redix.command!(redis, ["ZSCORE", "nx_test", "new"]))
        assert 3.0 == Veidrodelis.zscore(vdr_id(), 0, "nx_test", "new")
      end
    end

    test "ZADD with options: XX only updates existing members", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "xx_test", "1", "existing"])
      Redix.command!(redis, ["ZADD", "xx_test", "XX", "5", "existing", "3", "new"])

      assert_within 1000 do
        # "existing" should be updated to 5
        # "new" should NOT be added
        redis_score_existing = Redix.command!(redis, ["ZSCORE", "xx_test", "existing"])
        ts_score_existing = Veidrodelis.zscore(vdr_id(), 0, "xx_test", "existing")
        ts_score_new = Veidrodelis.zscore(vdr_id(), 0, "xx_test", "new")

        assert {5.0, ""} == Float.parse(redis_score_existing)
        assert 5.0 == ts_score_existing
        assert nil == ts_score_new
      end
    end

    test "ZADD with options: GT only updates if new score greater", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "gt_test", "5", "member"])
      # Should not update (3 < 5)
      Redix.command!(redis, ["ZADD", "gt_test", "GT", "3", "member"])

      assert_within 1000 do
        redis_score = Redix.command!(redis, ["ZSCORE", "gt_test", "member"])
        ts_score = Veidrodelis.zscore(vdr_id(), 0, "gt_test", "member")

        assert {5.0, ""} == Float.parse(redis_score)
        assert 5.0 == ts_score
      end
    end

    test "ZADD with options: LT only updates if new score less", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "lt_test", "5", "member"])
      # Should update (3 < 5)
      Redix.command!(redis, ["ZADD", "lt_test", "LT", "3", "member"])

      assert_within 1000 do
        redis_score = Redix.command!(redis, ["ZSCORE", "lt_test", "member"])
        ts_score = Veidrodelis.zscore(vdr_id(), 0, "lt_test", "member")

        Float.parse(redis_score) == {3.0, ""} and ts_score == 3.0
      end
    end

    test "ZADD with options: INCR increments score", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "incr_test", "5", "member"])
      # Should be 5 + 3 = 8
      Redix.command!(redis, ["ZADD", "incr_test", "INCR", "3", "member"])

      assert_within 1000 do
        redis_score = Redix.command!(redis, ["ZSCORE", "incr_test", "member"])
        ts_score = Veidrodelis.zscore(vdr_id(), 0, "incr_test", "member")

        assert {8.0, ""} == Float.parse(redis_score)
        assert 8.0 == ts_score
      end
    end

    test "ZINCRBY increments existing member in existing key", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zincrby_existing", "10.0", "counter"])
      # Should be 10.0 + 5.5 = 15.5
      Redix.command!(redis, ["ZINCRBY", "zincrby_existing", "5.5", "counter"])

      assert_within 1000 do
        redis_score = Redix.command!(redis, ["ZSCORE", "zincrby_existing", "counter"])
        ts_score = Veidrodelis.zscore(vdr_id(), 0, "zincrby_existing", "counter")

        assert {15.5, ""} == Float.parse(redis_score)
        assert 15.5 == ts_score
      end
    end

    test "ZINCRBY creates member in existing key", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zincrby_new_member", "1.0", "existing"])
      # Should create "new_member" with score 7.5 (0 + 7.5)
      Redix.command!(redis, ["ZINCRBY", "zincrby_new_member", "7.5", "new_member"])

      assert_within 1000 do
        redis_count = Redix.command!(redis, ["ZCARD", "zincrby_new_member"])
        ts_count = Veidrodelis.zcard(vdr_id(), 0, "zincrby_new_member")
        redis_score = Redix.command!(redis, ["ZSCORE", "zincrby_new_member", "new_member"])
        ts_score = Veidrodelis.zscore(vdr_id(), 0, "zincrby_new_member", "new_member")

        assert 2 == redis_count
        assert 2 == ts_count
        assert {7.5, ""} == Float.parse(redis_score)
        assert 7.5 == ts_score
      end
    end

    test "ZINCRBY creates key and member when key doesn't exist", %{redis: redis} do
      # Should create key and member with score 42.0 (0 + 42.0)
      Redix.command!(redis, ["ZINCRBY", "zincrby_new_key", "42.0", "member1"])

      assert_within 1000 do
        redis_count = Redix.command!(redis, ["ZCARD", "zincrby_new_key"])
        ts_count = Veidrodelis.zcard(vdr_id(), 0, "zincrby_new_key")
        redis_score = Redix.command!(redis, ["ZSCORE", "zincrby_new_key", "member1"])
        ts_score = Veidrodelis.zscore(vdr_id(), 0, "zincrby_new_key", "member1")

        assert 1 == redis_count
        assert 1 == ts_count
        assert {42.0, ""} == Float.parse(redis_score)
        assert 42.0 == ts_score
      end
    end

    test "ZINCRBY decrements with negative increment", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zincrby_decr", "100.0", "score"])
      # Should be 100.0 + (-25.5) = 74.5
      Redix.command!(redis, ["ZINCRBY", "zincrby_decr", "-25.5", "score"])

      assert_within 1000 do
        redis_score = Redix.command!(redis, ["ZSCORE", "zincrby_decr", "score"])
        ts_score = Veidrodelis.zscore(vdr_id(), 0, "zincrby_decr", "score")

        assert {74.5, ""} == Float.parse(redis_score)
        assert 74.5 == ts_score
      end
    end

    test "ZREMRANGEBYSCORE with exclusive min boundary", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "excl_min", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZREMRANGEBYSCORE", "excl_min", "(2", "3"])

      assert_within 1000 do
        # Only "c" removed (score 3), "b" (score 2) kept
        expected = ["a", "b", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "excl_min", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "excl_min", 0, -1, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZREMRANGEBYSCORE with exclusive max boundary", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "excl_max", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZREMRANGEBYSCORE", "excl_max", "2", "(3"])

      assert_within 1000 do
        # Only "b" removed (score 2), "c" (score 3) kept
        expected = ["a", "c", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "excl_max", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "excl_max", 0, -1, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZREMRANGEBYSCORE with both exclusive boundaries", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "excl_both", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZREMRANGEBYSCORE", "excl_both", "(2", "(4"])

      assert_within 1000 do
        # Only "c" removed, "b" and "d" kept
        expected = ["a", "b", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "excl_both", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "excl_both", 0, -1, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZREMRANGEBYSCORE from -inf to value", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "inf_min", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZREMRANGEBYSCORE", "inf_min", "-inf", "2"])

      assert_within 1000 do
        # "a" and "b" removed
        expected = ["c", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "inf_min", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "inf_min", 0, -1, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZREMRANGEBYSCORE from value to +inf", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "inf_max", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZREMRANGEBYSCORE", "inf_max", "3", "+inf"])

      assert_within 1000 do
        # "c" and "d" removed
        expected = ["a", "b"]
        redis_members = Redix.command!(redis, ["ZRANGE", "inf_max", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "inf_max", 0, -1, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZREMRANGEBYSCORE from -inf to +inf removes all", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "inf_all", "1", "a", "2", "b", "3", "c"])
      Redix.command!(redis, ["ZREMRANGEBYSCORE", "inf_all", "-inf", "+inf"])

      assert_within 1000 do
        redis_card = Redix.command!(redis, ["ZCARD", "inf_all"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "inf_all")

        assert 0 == redis_card
        assert 0 == ts_card
      end
    end

    test "ZREMRANGEBYLEX with inclusive range", %{redis: redis} do
      # All members must have same score for lex operations
      Redix.command!(redis, ["ZADD", "lex_incl", "0", "a", "0", "b", "0", "c", "0", "d"])
      Redix.command!(redis, ["ZREMRANGEBYLEX", "lex_incl", "[b", "[c"])

      assert_within 1000 do
        # "b" and "c" removed
        expected = ["a", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "lex_incl", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "lex_incl", 0, -1, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZREMRANGEBYLEX with exclusive range", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "lex_excl", "0", "a", "0", "b", "0", "c", "0", "d"])
      Redix.command!(redis, ["ZREMRANGEBYLEX", "lex_excl", "(a", "(d"])

      assert_within 1000 do
        # "b" and "c" removed, "a" and "d" kept
        expected = ["a", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "lex_excl", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "lex_excl", 0, -1, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZREMRANGEBYLEX with - (min) boundary", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "lex_min", "0", "a", "0", "b", "0", "c", "0", "d"])
      Redix.command!(redis, ["ZREMRANGEBYLEX", "lex_min", "-", "[b"])

      assert_within 1000 do
        # "a" and "b" removed
        expected = ["c", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "lex_min", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "lex_min", 0, -1, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZREMRANGEBYLEX with + (max) boundary", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "lex_max", "0", "a", "0", "b", "0", "c", "0", "d"])
      Redix.command!(redis, ["ZREMRANGEBYLEX", "lex_max", "[c", "+"])

      assert_within 1000 do
        # "c" and "d" removed
        expected = ["a", "b"]
        redis_members = Redix.command!(redis, ["ZRANGE", "lex_max", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "lex_max", 0, -1, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZREMRANGEBYLEX from - to + removes all", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "lex_all", "0", "a", "0", "b", "0", "c"])
      Redix.command!(redis, ["ZREMRANGEBYLEX", "lex_all", "-", "+"])

      assert_within 1000 do
        redis_card = Redix.command!(redis, ["ZCARD", "lex_all"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "lex_all")

        assert 0 == redis_card
        assert 0 == ts_card
      end
    end

    test "ZADD with infinity scores", %{redis: redis} do
      # Redis supports +inf and -inf as scores
      Redix.command!(redis, ["ZADD", "inf_scores", "-inf", "min", "0", "mid", "+inf", "max"])

      assert_within 1000 do
        expected = ["min", "mid", "max"]
        redis_members = Redix.command!(redis, ["ZRANGE", "inf_scores", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "inf_scores", 0, -1, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZREMRANGEBYSCORE with infinity score members", %{redis: redis} do
      Redix.command!(redis, [
        "ZADD",
        "inf_members",
        "-inf",
        "minval",
        "1",
        "a",
        "2",
        "b",
        "+inf",
        "maxval"
      ])

      # Remove from score 1 to +inf (inclusive)
      Redix.command!(redis, ["ZREMRANGEBYSCORE", "inf_members", "1", "+inf"])

      assert_within 1000 do
        # Only -inf member remains
        expected = ["minval"]
        redis_members = Redix.command!(redis, ["ZRANGE", "inf_members", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "inf_members", 0, -1, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZUNIONSTORE with WEIGHTS", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "union_w1", "1", "a", "2", "b"])
      Redix.command!(redis, ["ZADD", "union_w2", "1", "b", "3", "c"])

      Redix.command!(redis, [
        "ZUNIONSTORE",
        "union_weighted",
        "2",
        "union_w1",
        "union_w2",
        "WEIGHTS",
        "2",
        "3"
      ])

      assert_within 1000 do
        # a: 1*2 = 2, b: 2*2 + 1*3 = 7, c: 3*3 = 9
        redis_score_b = Redix.command!(redis, ["ZSCORE", "union_weighted", "b"])
        ts_score_b = Veidrodelis.zscore(vdr_id(), 0, "union_weighted", "b")

        Float.parse(redis_score_b) == {7.0, ""} and ts_score_b == 7.0
      end
    end

    test "ZUNIONSTORE with AGGREGATE MIN", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "union_min1", "1", "a", "5", "b"])
      Redix.command!(redis, ["ZADD", "union_min2", "3", "b", "2", "c"])

      Redix.command!(redis, [
        "ZUNIONSTORE",
        "union_min_result",
        "2",
        "union_min1",
        "union_min2",
        "AGGREGATE",
        "MIN"
      ])

      assert_within 1000 do
        # b should have min(5, 3) = 3
        redis_score_b = Redix.command!(redis, ["ZSCORE", "union_min_result", "b"])
        ts_score_b = Veidrodelis.zscore(vdr_id(), 0, "union_min_result", "b")

        Float.parse(redis_score_b) == {3.0, ""} and ts_score_b == 3.0
      end
    end

    test "ZUNIONSTORE with AGGREGATE MAX", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "union_max1", "1", "a", "5", "b"])
      Redix.command!(redis, ["ZADD", "union_max2", "3", "b", "2", "c"])

      Redix.command!(redis, [
        "ZUNIONSTORE",
        "union_max_result",
        "2",
        "union_max1",
        "union_max2",
        "AGGREGATE",
        "MAX"
      ])

      assert_within 1000 do
        # b should have max(5, 3) = 5
        redis_score_b = Redix.command!(redis, ["ZSCORE", "union_max_result", "b"])
        ts_score_b = Veidrodelis.zscore(vdr_id(), 0, "union_max_result", "b")

        Float.parse(redis_score_b) == {5.0, ""} and ts_score_b == 5.0
      end
    end

    test "ZINTERSTORE with WEIGHTS", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "inter_w1", "1", "a", "2", "b"])
      Redix.command!(redis, ["ZADD", "inter_w2", "3", "b", "4", "c"])

      Redix.command!(redis, [
        "ZINTERSTORE",
        "inter_weighted",
        "2",
        "inter_w1",
        "inter_w2",
        "WEIGHTS",
        "2",
        "3"
      ])

      assert_within 1000 do
        # Only b is in both: 2*2 + 3*3 = 13
        redis_card = Redix.command!(redis, ["ZCARD", "inter_weighted"])
        ts_card = Veidrodelis.zcard(vdr_id(), 0, "inter_weighted")
        redis_score_b = Redix.command!(redis, ["ZSCORE", "inter_weighted", "b"])
        ts_score_b = Veidrodelis.zscore(vdr_id(), 0, "inter_weighted", "b")

        redis_card == 1 and ts_card == 1 and
          Float.parse(redis_score_b) == {13.0, ""} and ts_score_b == 13.0
      end
    end

    test "ZINTERSTORE with AGGREGATE MAX", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "inter_max1", "5", "b", "1", "a"])
      Redix.command!(redis, ["ZADD", "inter_max2", "3", "b", "2", "c"])

      Redix.command!(redis, [
        "ZINTERSTORE",
        "inter_max_result",
        "2",
        "inter_max1",
        "inter_max2",
        "AGGREGATE",
        "MAX"
      ])

      assert_within 1000 do
        # Only b: max(5, 3) = 5
        redis_score_b = Redix.command!(redis, ["ZSCORE", "inter_max_result", "b"])
        ts_score_b = Veidrodelis.zscore(vdr_id(), 0, "inter_max_result", "b")

        Float.parse(redis_score_b) == {5.0, ""} and ts_score_b == 5.0
      end
    end

    test "ZREMRANGEBYRANK with negative indices", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "rank_neg", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZREMRANGEBYRANK", "rank_neg", "-2", "-1"])

      assert_within 1000 do
        # Last two removed
        expected = ["a", "b"]
        redis_members = Redix.command!(redis, ["ZRANGE", "rank_neg", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "rank_neg", 0, -1, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZRANGEBYSCORE with scores replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrangebyscore_test", "1", "one", "2", "two", "3", "three", "4", "four", "5", "five"])

      assert_within 1000 do
        # Query range [2, 4]
        redis_result = Redix.command!(redis, ["ZRANGEBYSCORE", "zrangebyscore_test", "2", "4", "WITHSCORES"])
        ts_result = Veidrodelis.zrangebyscore(vdr_id(), 0, "zrangebyscore_test", 2.0, 4.0, true)

        # Redis returns flat list: ["two", "2", "three", "3", "four", "4"]
        # Veidrodelis returns tuples: [{"two", 2.0}, {"three", 3.0}, {"four", 4.0}]
        # Convert both to comparable format (members and numeric scores)
        parse_score = fn s ->
          case Float.parse(s) do
            {f, _} -> f
            :error -> String.to_integer(s) * 1.0
          end
        end
        redis_pairs = Enum.chunk_every(redis_result, 2) |> Enum.map(fn [m, s] -> {m, parse_score.(s)} end)

        assert redis_pairs == ts_result
      end
    end

    test "ZRANGEBYSCORE without scores replicates correctly", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrangebyscore_noscore", "1", "one", "2", "two", "3", "three", "4", "four", "5", "five"])

      assert_within 1000 do
        expected = ["two", "three", "four"]
        redis_members = Redix.command!(redis, ["ZRANGEBYSCORE", "zrangebyscore_noscore", "2", "4"])
        ts_members = Veidrodelis.zrangebyscore(vdr_id(), 0, "zrangebyscore_noscore", 2.0, 4.0, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZRANGEBYSCORE with negative scores", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrangebyscore_neg", "-3", "a", "-1", "b", "0", "c", "2", "d"])

      assert_within 1000 do
        expected = ["a", "b", "c"]
        redis_members = Redix.command!(redis, ["ZRANGEBYSCORE", "zrangebyscore_neg", "-3", "0"])
        ts_members = Veidrodelis.zrangebyscore(vdr_id(), 0, "zrangebyscore_neg", -3.0, 0.0, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZRANGEBYSCORE with floating point scores", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrangebyscore_float", "1.5", "a", "2.7", "b", "3.2", "c", "4.9", "d"])

      assert_within 1000 do
        expected = ["b", "c"]
        redis_members = Redix.command!(redis, ["ZRANGEBYSCORE", "zrangebyscore_float", "2.0", "4.0"])
        ts_members = Veidrodelis.zrangebyscore(vdr_id(), 0, "zrangebyscore_float", 2.0, 4.0, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZRANGEBYSCORE with min equals max", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrangebyscore_equal", "1", "one", "2", "two", "3", "three"])

      assert_within 1000 do
        expected = ["two"]
        redis_members = Redix.command!(redis, ["ZRANGEBYSCORE", "zrangebyscore_equal", "2", "2"])
        ts_members = Veidrodelis.zrangebyscore(vdr_id(), 0, "zrangebyscore_equal", 2.0, 2.0, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZRANGEBYSCORE with empty range", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrangebyscore_empty", "1", "one", "5", "five", "10", "ten"])

      assert_within 1000 do
        expected = []
        redis_members = Redix.command!(redis, ["ZRANGEBYSCORE", "zrangebyscore_empty", "2", "4"])
        ts_members = Veidrodelis.zrangebyscore(vdr_id(), 0, "zrangebyscore_empty", 2.0, 4.0, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZRANGEBYSCORE on non-existent key", %{redis: redis} do
      assert_within 1000 do
        expected = []
        redis_members = Redix.command!(redis, ["ZRANGEBYSCORE", "nonexistent_zset", "1", "10"])
        ts_members = Veidrodelis.zrangebyscore(vdr_id(), 0, "nonexistent_zset", 1.0, 10.0, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZRANGEBYSCORE with large score range", %{redis: redis} do
      # Add 100 members with scores 1-100
      args = Enum.flat_map(1..100, fn i -> [to_string(i), "member_#{i}"] end)
      Redix.command!(redis, ["ZADD", "zrangebyscore_large" | args])

      assert_within 1000 do
        expected_count = 51  # Scores 25-75 inclusive
        redis_members = Redix.command!(redis, ["ZRANGEBYSCORE", "zrangebyscore_large", "25", "75"])
        ts_members = Veidrodelis.zrangebyscore(vdr_id(), 0, "zrangebyscore_large", 25.0, 75.0, false)

        assert length(redis_members) == expected_count
        assert length(ts_members) == expected_count
      end
    end

    test "ZPOPMAX with count", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "popmax_count", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZPOPMAX", "popmax_count", "2"])

      assert_within 1000 do
        # Top 2 (d, c) removed
        expected = ["a", "b"]
        redis_members = Redix.command!(redis, ["ZRANGE", "popmax_count", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "popmax_count", 0, -1, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZPOPMIN with count", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "popmin_count", "1", "a", "2", "b", "3", "c", "4", "d"])
      Redix.command!(redis, ["ZPOPMIN", "popmin_count", "2"])

      assert_within 1000 do
        # Bottom 2 (a, b) removed
        expected = ["c", "d"]
        redis_members = Redix.command!(redis, ["ZRANGE", "popmin_count", "0", "-1"])
        ts_members = Veidrodelis.zrange(vdr_id(), 0, "popmin_count", 0, -1, false)

        assert expected == redis_members
        assert expected == ts_members
      end
    end

    test "ZRANK returns correct rank in ascending order", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrank_test", "1", "one", "2", "two", "3", "three", "4", "four"])

      assert_within 1000 do
        # Ranks: one=0, two=1, three=2, four=3
        redis_rank_one = Redix.command!(redis, ["ZRANK", "zrank_test", "one"])
        ts_rank_one = Veidrodelis.zrank(vdr_id(), 0, "zrank_test", "one")
        redis_rank_three = Redix.command!(redis, ["ZRANK", "zrank_test", "three"])
        ts_rank_three = Veidrodelis.zrank(vdr_id(), 0, "zrank_test", "three")
        redis_rank_four = Redix.command!(redis, ["ZRANK", "zrank_test", "four"])
        ts_rank_four = Veidrodelis.zrank(vdr_id(), 0, "zrank_test", "four")

        assert 0 == redis_rank_one
        assert 0 == ts_rank_one
        assert 2 == redis_rank_three
        assert 2 == ts_rank_three
        assert 3 == redis_rank_four
        assert 3 == ts_rank_four
      end
    end

    test "ZRANK returns nil for non-existent member", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrank_missing", "1", "one", "2", "two"])

      assert_within 1000 do
        redis_rank = Redix.command!(redis, ["ZRANK", "zrank_missing", "nonexistent"])
        ts_rank = Veidrodelis.zrank(vdr_id(), 0, "zrank_missing", "nonexistent")

        assert nil == redis_rank
        assert nil == ts_rank
      end
    end

    test "ZRANK returns nil for non-existent key", %{redis: redis} do
      assert_within 1000 do
        redis_rank = Redix.command!(redis, ["ZRANK", "nonexistent_key", "member"])
        ts_rank = Veidrodelis.zrank(vdr_id(), 0, "nonexistent_key", "member")

        assert nil == redis_rank
        assert nil == ts_rank
      end
    end

    test "ZRANK with duplicate scores returns rank based on member order", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrank_dup", "1", "a", "1", "b", "1", "c"])

      assert_within 1000 do
        # With same scores, members are ordered lexicographically
        redis_rank_a = Redix.command!(redis, ["ZRANK", "zrank_dup", "a"])
        ts_rank_a = Veidrodelis.zrank(vdr_id(), 0, "zrank_dup", "a")
        redis_rank_b = Redix.command!(redis, ["ZRANK", "zrank_dup", "b"])
        ts_rank_b = Veidrodelis.zrank(vdr_id(), 0, "zrank_dup", "b")
        redis_rank_c = Redix.command!(redis, ["ZRANK", "zrank_dup", "c"])
        ts_rank_c = Veidrodelis.zrank(vdr_id(), 0, "zrank_dup", "c")

        assert 0 == redis_rank_a
        assert 0 == ts_rank_a
        assert 1 == redis_rank_b
        assert 1 == ts_rank_b
        assert 2 == redis_rank_c
        assert 2 == ts_rank_c
      end
    end

    test "ZRANK with negative scores", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrank_neg", "-3", "a", "-1", "b", "0", "c", "2", "d"])

      assert_within 1000 do
        # Ranks: a=0, b=1, c=2, d=3
        redis_rank_a = Redix.command!(redis, ["ZRANK", "zrank_neg", "a"])
        ts_rank_a = Veidrodelis.zrank(vdr_id(), 0, "zrank_neg", "a")
        redis_rank_d = Redix.command!(redis, ["ZRANK", "zrank_neg", "d"])
        ts_rank_d = Veidrodelis.zrank(vdr_id(), 0, "zrank_neg", "d")

        assert 0 == redis_rank_a
        assert 0 == ts_rank_a
        assert 3 == redis_rank_d
        assert 3 == ts_rank_d
      end
    end

    test "ZREVRANK returns correct rank in descending order", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrevrank_test", "1", "one", "2", "two", "3", "three", "4", "four"])

      assert_within 1000 do
        # Reverse ranks: four=0, three=1, two=2, one=3
        redis_rank_four = Redix.command!(redis, ["ZREVRANK", "zrevrank_test", "four"])
        ts_rank_four = Veidrodelis.zrevrank(vdr_id(), 0, "zrevrank_test", "four")
        redis_rank_three = Redix.command!(redis, ["ZREVRANK", "zrevrank_test", "three"])
        ts_rank_three = Veidrodelis.zrevrank(vdr_id(), 0, "zrevrank_test", "three")
        redis_rank_one = Redix.command!(redis, ["ZREVRANK", "zrevrank_test", "one"])
        ts_rank_one = Veidrodelis.zrevrank(vdr_id(), 0, "zrevrank_test", "one")

        assert 0 == redis_rank_four
        assert 0 == ts_rank_four
        assert 1 == redis_rank_three
        assert 1 == ts_rank_three
        assert 3 == redis_rank_one
        assert 3 == ts_rank_one
      end
    end

    test "ZREVRANK returns nil for non-existent member", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrevrank_missing", "1", "one", "2", "two"])

      assert_within 1000 do
        redis_rank = Redix.command!(redis, ["ZREVRANK", "zrevrank_missing", "nonexistent"])
        ts_rank = Veidrodelis.zrevrank(vdr_id(), 0, "zrevrank_missing", "nonexistent")

        assert nil == redis_rank
        assert nil == ts_rank
      end
    end

    test "ZREVRANK returns nil for non-existent key", %{redis: redis} do
      assert_within 1000 do
        redis_rank = Redix.command!(redis, ["ZREVRANK", "nonexistent_key", "member"])
        ts_rank = Veidrodelis.zrevrank(vdr_id(), 0, "nonexistent_key", "member")

        assert nil == redis_rank
        assert nil == ts_rank
      end
    end

    test "ZREVRANK with duplicate scores returns rank based on member order", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrevrank_dup", "1", "a", "1", "b", "1", "c"])

      assert_within 1000 do
        # With same scores, members are ordered lexicographically (c, b, a in reverse)
        redis_rank_c = Redix.command!(redis, ["ZREVRANK", "zrevrank_dup", "c"])
        ts_rank_c = Veidrodelis.zrevrank(vdr_id(), 0, "zrevrank_dup", "c")
        redis_rank_b = Redix.command!(redis, ["ZREVRANK", "zrevrank_dup", "b"])
        ts_rank_b = Veidrodelis.zrevrank(vdr_id(), 0, "zrevrank_dup", "b")
        redis_rank_a = Redix.command!(redis, ["ZREVRANK", "zrevrank_dup", "a"])
        ts_rank_a = Veidrodelis.zrevrank(vdr_id(), 0, "zrevrank_dup", "a")

        assert 0 == redis_rank_c
        assert 0 == ts_rank_c
        assert 1 == redis_rank_b
        assert 1 == ts_rank_b
        assert 2 == redis_rank_a
        assert 2 == ts_rank_a
      end
    end

    test "ZREVRANK with negative scores", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "zrevrank_neg", "-3", "a", "-1", "b", "0", "c", "2", "d"])

      assert_within 1000 do
        # Reverse ranks: d=0, c=1, b=2, a=3
        redis_rank_d = Redix.command!(redis, ["ZREVRANK", "zrevrank_neg", "d"])
        ts_rank_d = Veidrodelis.zrevrank(vdr_id(), 0, "zrevrank_neg", "d")
        redis_rank_a = Redix.command!(redis, ["ZREVRANK", "zrevrank_neg", "a"])
        ts_rank_a = Veidrodelis.zrevrank(vdr_id(), 0, "zrevrank_neg", "a")

        assert 0 == redis_rank_d
        assert 0 == ts_rank_d
        assert 3 == redis_rank_a
        assert 3 == ts_rank_a
      end
    end

    test "ZRANK and ZREVRANK are consistent inverses", %{redis: redis} do
      Redix.command!(redis, ["ZADD", "rank_inverse", "1", "one", "2", "two", "3", "three"])

      assert_within 1000 do
        # Get the size of the set
        redis_size = Redix.command!(redis, ["ZCARD", "rank_inverse"])
        ts_size = Veidrodelis.zcard(vdr_id(), 0, "rank_inverse")

        # ZRANK + ZREVRANK should equal size - 1
        redis_rank = Redix.command!(redis, ["ZRANK", "rank_inverse", "two"])
        ts_rank = Veidrodelis.zrank(vdr_id(), 0, "rank_inverse", "two")
        redis_revrank = Redix.command!(redis, ["ZREVRANK", "rank_inverse", "two"])
        ts_revrank = Veidrodelis.zrevrank(vdr_id(), 0, "rank_inverse", "two")

        assert redis_rank + redis_revrank == redis_size - 1
        assert ts_rank + ts_revrank == ts_size - 1
      end
    end
  end
end
