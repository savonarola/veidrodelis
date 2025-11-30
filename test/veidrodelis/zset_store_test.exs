defmodule Veidrodelis.ZsetStoreTest do
  use ExUnit.Case, async: true

  alias Veidrodelis.ZsetStore

  setup do
    # Simple decode function that returns members as-is
    decode_fun = fn _key, member -> member end

    store = ZsetStore.new(decode_fun)

    {:ok, store: store}
  end

  describe "new/1" do
    test "creates a new ETS table and returns a struct" do
      decode_fun = fn _key, member -> member end
      store = ZsetStore.new(decode_fun)

      assert %ZsetStore{
               tid: tid,
               decode_fun: ^decode_fun
             } = store

      assert is_reference(tid)

      # Clean up
      ZsetStore.destroy(store)
    end
  end

  describe "zadd/4" do
    test "adds members with scores to a sorted set", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "myzset", [{1.0, "one"}, {2.0, "two"}])

      assert ZsetStore.zscore(store, 0, "myzset", "one") == 1.0
      assert ZsetStore.zscore(store, 0, "myzset", "two") == 2.0
    end

    test "updates existing member scores", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "myzset", [{1.0, "member"}])
      assert ZsetStore.zscore(store, 0, "myzset", "member") == 1.0

      :ok = ZsetStore.zadd(store, 0, "myzset", [{5.0, "member"}])
      assert ZsetStore.zscore(store, 0, "myzset", "member") == 5.0
      assert ZsetStore.zcard(store, 0, "myzset") == 1
    end

    test "supports multiple databases", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "myzset", [{1.0, "member"}])
      :ok = ZsetStore.zadd(store, 1, "myzset", [{2.0, "member"}])

      assert ZsetStore.zscore(store, 0, "myzset", "member") == 1.0
      assert ZsetStore.zscore(store, 1, "myzset", "member") == 2.0
    end

    test "adds multiple members at once", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      assert ZsetStore.zcard(store, 0, "myzset") == 3
    end

    test "adds empty list of members", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "myzset", [])

      assert ZsetStore.zcard(store, 0, "myzset") == 0
    end
  end

  describe "zadd_final/5" do
    test "adds a member with final score", %{store: store} do
      :ok = ZsetStore.zadd_final(store, 0, "myzset", 10.5, "member")

      assert ZsetStore.zscore(store, 0, "myzset", "member") == 10.5
    end
  end

  describe "zrem/4" do
    test "removes members from a sorted set", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      :ok = ZsetStore.zrem(store, 0, "myzset", ["two"])

      assert ZsetStore.zscore(store, 0, "myzset", "one") == 1.0
      assert ZsetStore.zscore(store, 0, "myzset", "two") == nil
      assert ZsetStore.zscore(store, 0, "myzset", "three") == 3.0
    end

    test "removing non-existent members is safe", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "myzset", [{1.0, "one"}])
      :ok = ZsetStore.zrem(store, 0, "myzset", ["nonexistent"])

      assert ZsetStore.zscore(store, 0, "myzset", "one") == 1.0
      assert ZsetStore.zcard(store, 0, "myzset") == 1
    end

    test "removes multiple members at once", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      :ok = ZsetStore.zrem(store, 0, "myzset", ["one", "three"])

      assert ZsetStore.zscore(store, 0, "myzset", "one") == nil
      assert ZsetStore.zscore(store, 0, "myzset", "two") == 2.0
      assert ZsetStore.zscore(store, 0, "myzset", "three") == nil
    end
  end

  describe "zremrangebyrank/5" do
    test "removes members by rank range", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"},
          {4.0, "four"},
          {5.0, "five"}
        ])

      :ok = ZsetStore.zremrangebyrank(store, 0, "myzset", 1, 3)

      assert ZsetStore.zcard(store, 0, "myzset") == 2
      assert ZsetStore.zscore(store, 0, "myzset", "one") == 1.0
      assert ZsetStore.zscore(store, 0, "myzset", "two") == nil
      assert ZsetStore.zscore(store, 0, "myzset", "three") == nil
      assert ZsetStore.zscore(store, 0, "myzset", "four") == nil
      assert ZsetStore.zscore(store, 0, "myzset", "five") == 5.0
    end

    test "supports negative rank indices", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      # Remove last element (rank -1)
      :ok = ZsetStore.zremrangebyrank(store, 0, "myzset", -1, -1)

      assert ZsetStore.zcard(store, 0, "myzset") == 2
      assert ZsetStore.zscore(store, 0, "myzset", "three") == nil
    end

    test "removes all members with full range", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      :ok = ZsetStore.zremrangebyrank(store, 0, "myzset", 0, -1)

      assert ZsetStore.zcard(store, 0, "myzset") == 0
    end
  end

  describe "zremrangebyscore/5" do
    test "removes members by score range", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"},
          {4.0, "four"},
          {5.0, "five"}
        ])

      :ok = ZsetStore.zremrangebyscore(store, 0, "myzset", 2.0, 4.0)

      assert ZsetStore.zcard(store, 0, "myzset") == 2
      assert ZsetStore.zscore(store, 0, "myzset", "one") == 1.0
      assert ZsetStore.zscore(store, 0, "myzset", "two") == nil
      assert ZsetStore.zscore(store, 0, "myzset", "five") == 5.0
    end

    test "supports unbounded ranges with infinity", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      :ok = ZsetStore.zremrangebyscore(store, 0, "myzset", :neg_inf, 2.0)

      assert ZsetStore.zcard(store, 0, "myzset") == 1
      assert ZsetStore.zscore(store, 0, "myzset", "three") == 3.0
    end
  end

  describe "zremrangebylex/5" do
    test "removes members by lexicographical range", %{store: store} do
      # All members with same score for lex ordering
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {0.0, "apple"},
          {0.0, "banana"},
          {0.0, "cherry"},
          {0.0, "date"}
        ])

      :ok = ZsetStore.zremrangebylex(store, 0, "myzset", "banana", "cherry")

      assert ZsetStore.zcard(store, 0, "myzset") == 2
      assert ZsetStore.zscore(store, 0, "myzset", "apple") == 0.0
      assert ZsetStore.zscore(store, 0, "myzset", "banana") == nil
      assert ZsetStore.zscore(store, 0, "myzset", "cherry") == nil
      assert ZsetStore.zscore(store, 0, "myzset", "date") == 0.0
    end
  end

  describe "zpopmin/4" do
    test "removes and returns member with lowest score", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {3.0, "three"},
          {1.0, "one"},
          {2.0, "two"}
        ])

      result = ZsetStore.zpopmin(store, 0, "myzset")

      assert result == [{"one", 1.0}]
      assert ZsetStore.zcard(store, 0, "myzset") == 2
      assert ZsetStore.zscore(store, 0, "myzset", "one") == nil
    end

    test "removes and returns multiple members with lowest scores", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"},
          {4.0, "four"}
        ])

      result = ZsetStore.zpopmin(store, 0, "myzset", 2)

      assert result == [{"one", 1.0}, {"two", 2.0}]
      assert ZsetStore.zcard(store, 0, "myzset") == 2
    end

    test "returns empty list for non-existent zset", %{store: store} do
      result = ZsetStore.zpopmin(store, 0, "nonexistent")

      assert result == []
    end
  end

  describe "zpopmax/4" do
    test "removes and returns member with highest score", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {3.0, "three"},
          {1.0, "one"},
          {2.0, "two"}
        ])

      result = ZsetStore.zpopmax(store, 0, "myzset")

      assert result == [{"three", 3.0}]
      assert ZsetStore.zcard(store, 0, "myzset") == 2
      assert ZsetStore.zscore(store, 0, "myzset", "three") == nil
    end

    test "removes and returns multiple members with highest scores", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"},
          {4.0, "four"}
        ])

      result = ZsetStore.zpopmax(store, 0, "myzset", 2)

      assert result == [{"four", 4.0}, {"three", 3.0}]
      assert ZsetStore.zcard(store, 0, "myzset") == 2
    end
  end

  describe "zunionstore/6" do
    test "computes union of two sorted sets with default weights and sum", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "zset1", [{1.0, "a"}, {2.0, "b"}])
      :ok = ZsetStore.zadd(store, 0, "zset2", [{1.0, "b"}, {2.0, "c"}])

      :ok = ZsetStore.zunionstore(store, 0, "dest", ["zset1", "zset2"])

      assert ZsetStore.zcard(store, 0, "dest") == 3
      assert ZsetStore.zscore(store, 0, "dest", "a") == 1.0
      # 2.0 + 1.0
      assert ZsetStore.zscore(store, 0, "dest", "b") == 3.0
      assert ZsetStore.zscore(store, 0, "dest", "c") == 2.0
    end

    test "computes union with weights", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "zset1", [{1.0, "a"}, {2.0, "b"}])
      :ok = ZsetStore.zadd(store, 0, "zset2", [{1.0, "b"}, {2.0, "c"}])

      :ok = ZsetStore.zunionstore(store, 0, "dest", ["zset1", "zset2"], [2.0, 3.0])

      # 1.0 * 2
      assert ZsetStore.zscore(store, 0, "dest", "a") == 2.0
      # 2.0 * 2 + 1.0 * 3
      assert ZsetStore.zscore(store, 0, "dest", "b") == 7.0
      # 2.0 * 3
      assert ZsetStore.zscore(store, 0, "dest", "c") == 6.0
    end

    test "computes union with MIN aggregate", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "zset1", [{5.0, "a"}, {2.0, "b"}])
      :ok = ZsetStore.zadd(store, 0, "zset2", [{3.0, "a"}, {4.0, "b"}])

      :ok = ZsetStore.zunionstore(store, 0, "dest", ["zset1", "zset2"], [], :min)

      assert ZsetStore.zscore(store, 0, "dest", "a") == 3.0
      assert ZsetStore.zscore(store, 0, "dest", "b") == 2.0
    end

    test "computes union with MAX aggregate", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "zset1", [{5.0, "a"}, {2.0, "b"}])
      :ok = ZsetStore.zadd(store, 0, "zset2", [{3.0, "a"}, {4.0, "b"}])

      :ok = ZsetStore.zunionstore(store, 0, "dest", ["zset1", "zset2"], [], :max)

      assert ZsetStore.zscore(store, 0, "dest", "a") == 5.0
      assert ZsetStore.zscore(store, 0, "dest", "b") == 4.0
    end

    test "overwrites existing destination", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "zset1", [{1.0, "a"}])
      :ok = ZsetStore.zadd(store, 0, "dest", [{99.0, "old"}])

      :ok = ZsetStore.zunionstore(store, 0, "dest", ["zset1"])

      assert ZsetStore.zcard(store, 0, "dest") == 1
      assert ZsetStore.zscore(store, 0, "dest", "a") == 1.0
      assert ZsetStore.zscore(store, 0, "dest", "old") == nil
    end
  end

  describe "zinterstore/6" do
    test "computes intersection of two sorted sets with default weights and sum", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "zset1", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}])
      :ok = ZsetStore.zadd(store, 0, "zset2", [{1.0, "b"}, {2.0, "c"}, {3.0, "d"}])

      :ok = ZsetStore.zinterstore(store, 0, "dest", ["zset1", "zset2"])

      assert ZsetStore.zcard(store, 0, "dest") == 2
      assert ZsetStore.zscore(store, 0, "dest", "a") == nil
      # 2.0 + 1.0
      assert ZsetStore.zscore(store, 0, "dest", "b") == 3.0
      # 3.0 + 2.0
      assert ZsetStore.zscore(store, 0, "dest", "c") == 5.0
      assert ZsetStore.zscore(store, 0, "dest", "d") == nil
    end

    test "computes intersection with weights", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "zset1", [{1.0, "a"}, {2.0, "b"}])
      :ok = ZsetStore.zadd(store, 0, "zset2", [{1.0, "b"}, {2.0, "c"}])

      :ok = ZsetStore.zinterstore(store, 0, "dest", ["zset1", "zset2"], [2.0, 3.0])

      assert ZsetStore.zcard(store, 0, "dest") == 1
      # 2.0 * 2 + 1.0 * 3
      assert ZsetStore.zscore(store, 0, "dest", "b") == 7.0
    end

    test "computes intersection with MIN aggregate", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "zset1", [{5.0, "a"}, {2.0, "b"}])
      :ok = ZsetStore.zadd(store, 0, "zset2", [{3.0, "a"}, {4.0, "b"}])

      :ok = ZsetStore.zinterstore(store, 0, "dest", ["zset1", "zset2"], [], :min)

      assert ZsetStore.zscore(store, 0, "dest", "a") == 3.0
      assert ZsetStore.zscore(store, 0, "dest", "b") == 2.0
    end

    test "computes intersection with MAX aggregate", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "zset1", [{5.0, "a"}, {2.0, "b"}])
      :ok = ZsetStore.zadd(store, 0, "zset2", [{3.0, "a"}, {4.0, "b"}])

      :ok = ZsetStore.zinterstore(store, 0, "dest", ["zset1", "zset2"], [], :max)

      assert ZsetStore.zscore(store, 0, "dest", "a") == 5.0
      assert ZsetStore.zscore(store, 0, "dest", "b") == 4.0
    end

    test "returns empty set when no common members", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "zset1", [{1.0, "a"}])
      :ok = ZsetStore.zadd(store, 0, "zset2", [{1.0, "b"}])

      :ok = ZsetStore.zinterstore(store, 0, "dest", ["zset1", "zset2"])

      assert ZsetStore.zcard(store, 0, "dest") == 0
    end
  end

  describe "zscore/4" do
    test "gets score for existing member", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "myzset", [{42.5, "member"}])

      assert ZsetStore.zscore(store, 0, "myzset", "member") == 42.5
    end

    test "returns nil for non-existent member", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "myzset", [{1.0, "member"}])

      assert ZsetStore.zscore(store, 0, "myzset", "nonexistent") == nil
    end

    test "returns nil for non-existent zset", %{store: store} do
      assert ZsetStore.zscore(store, 0, "nonexistent", "member") == nil
    end
  end

  describe "zcard/3" do
    test "returns the number of members in a sorted set", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      assert ZsetStore.zcard(store, 0, "myzset") == 3
    end

    test "returns 0 for non-existent zset", %{store: store} do
      assert ZsetStore.zcard(store, 0, "nonexistent") == 0
    end

    test "counts correctly with updates", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "myzset", [{1.0, "member"}])
      :ok = ZsetStore.zadd(store, 0, "myzset", [{5.0, "member"}])

      assert ZsetStore.zcard(store, 0, "myzset") == 1
    end
  end

  describe "zrange/5" do
    test "returns members in score order", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {3.0, "three"},
          {1.0, "one"},
          {2.0, "two"}
        ])

      result = ZsetStore.zrange(store, 0, "myzset", 0, -1)

      assert result == [{"one", 1.0}, {"two", 2.0}, {"three", 3.0}]
    end

    test "returns subset by rank range", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"},
          {4.0, "four"}
        ])

      result = ZsetStore.zrange(store, 0, "myzset", 1, 2)

      assert result == [{"two", 2.0}, {"three", 3.0}]
    end

    test "supports negative indices", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      result = ZsetStore.zrange(store, 0, "myzset", -2, -1)

      assert result == [{"two", 2.0}, {"three", 3.0}]
    end

    test "returns empty list for non-existent zset", %{store: store} do
      result = ZsetStore.zrange(store, 0, "nonexistent", 0, -1)

      assert result == []
    end
  end

  describe "zrangebyscore/5" do
    test "returns members in score range", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"},
          {4.0, "four"},
          {5.0, "five"}
        ])

      result = ZsetStore.zrangebyscore(store, 0, "myzset", 2.0, 4.0)

      assert length(result) == 3
      assert Enum.map(result, fn {_member, score} -> score end) == [2.0, 3.0, 4.0]
    end

    test "supports unbounded ranges", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      result = ZsetStore.zrangebyscore(store, 0, "myzset", :neg_inf, 2.0)

      assert length(result) == 2
    end
  end

  describe "del/3" do
    test "deletes an entire sorted set", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"}
        ])

      assert ZsetStore.zcard(store, 0, "myzset") == 2

      :ok = ZsetStore.del(store, 0, "myzset")

      assert ZsetStore.zcard(store, 0, "myzset") == 0
    end

    test "handles deleting non-existent zset", %{store: store} do
      :ok = ZsetStore.del(store, 0, "nonexistent")
    end

    test "only deletes specified database and key", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "myzset", [{1.0, "one"}])
      :ok = ZsetStore.zadd(store, 1, "myzset", [{1.0, "one"}])
      :ok = ZsetStore.zadd(store, 0, "other", [{1.0, "one"}])

      :ok = ZsetStore.del(store, 0, "myzset")

      assert ZsetStore.zcard(store, 0, "myzset") == 0
      assert ZsetStore.zcard(store, 1, "myzset") == 1
      assert ZsetStore.zcard(store, 0, "other") == 1
    end
  end

  describe "decode function" do
    test "uses custom decode function for member values" do
      # Decode function that converts to uppercase for case-insensitive storage
      decode_fun = fn _key, member -> String.upcase(member) end

      store = ZsetStore.new(decode_fun)

      :ok = ZsetStore.zadd(store, 0, "myzset", [{1.0, "apple"}, {2.0, "BANANA"}])

      # Members are stored by their decoded (uppercased) keys
      result = ZsetStore.zrange(store, 0, "myzset", 0, -1)
      decoded_members = Enum.map(result, fn {member, _score} -> member end)

      assert Enum.sort(decoded_members) == ["APPLE", "BANANA"]

      # Setting "APPLE" again should update (same decoded member)
      :ok = ZsetStore.zadd(store, 0, "myzset", [{5.0, "APPLE"}])
      assert ZsetStore.zcard(store, 0, "myzset") == 2
      assert ZsetStore.zscore(store, 0, "myzset", "apple") == 5.0

      # Clean up
      ZsetStore.destroy(store)
    end

    test "decode function receives key for context" do
      # Decode function that includes key prefix
      decode_fun = fn key, member -> {key, member} end

      store = ZsetStore.new(decode_fun)

      :ok = ZsetStore.zadd(store, 0, "zset1", [{1.0, "member"}])
      :ok = ZsetStore.zadd(store, 0, "zset2", [{2.0, "member"}])

      score1 = ZsetStore.zscore(store, 0, "zset1", "member")
      score2 = ZsetStore.zscore(store, 0, "zset2", "member")

      # Decoded members include the key
      assert score1 == 1.0
      assert score2 == 2.0

      # Clean up
      ZsetStore.destroy(store)
    end
  end

  describe "dual entry synchronization" do
    test "both ETS entries are kept in sync on add", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "myzset", [{1.0, "member"}])

      # Verify score lookup works (uses member-lookup entry)
      assert ZsetStore.zscore(store, 0, "myzset", "member") == 1.0

      # Verify range query works (uses score-indexed entry)
      result = ZsetStore.zrangebyscore(store, 0, "myzset", 0.0, 2.0)
      assert length(result) == 1
    end

    test "both ETS entries are kept in sync on update", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "myzset", [{1.0, "member"}])
      :ok = ZsetStore.zadd(store, 0, "myzset", [{5.0, "member"}])

      # Old score-indexed entry should be gone
      result_old = ZsetStore.zrangebyscore(store, 0, "myzset", 0.0, 2.0)
      assert length(result_old) == 0

      # New score should be in both entries
      assert ZsetStore.zscore(store, 0, "myzset", "member") == 5.0
      result_new = ZsetStore.zrangebyscore(store, 0, "myzset", 4.0, 6.0)
      assert length(result_new) == 1
    end

    test "both ETS entries are removed on delete", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "myzset", [{1.0, "member"}])
      :ok = ZsetStore.zrem(store, 0, "myzset", ["member"])

      # Both lookups should fail
      assert ZsetStore.zscore(store, 0, "myzset", "member") == nil
      result = ZsetStore.zrangebyscore(store, 0, "myzset", 0.0, 2.0)
      assert length(result) == 0
    end
  end

  describe "edge cases" do
    test "handles empty member names", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "myzset", [{1.0, ""}])

      assert ZsetStore.zscore(store, 0, "myzset", "") == 1.0
    end

    test "handles binary member names", %{store: store} do
      :ok = ZsetStore.zadd(store, 0, "myzset", [{1.0, <<1, 2, 3>>}])

      assert ZsetStore.zscore(store, 0, "myzset", <<1, 2, 3>>) == 1.0
    end

    test "handles same score for multiple members", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.0, "a"},
          {1.0, "b"},
          {1.0, "c"}
        ])

      result = ZsetStore.zrange(store, 0, "myzset", 0, -1)
      assert length(result) == 3
      assert Enum.all?(result, fn {_member, score} -> score == 1.0 end)
    end

    test "handles negative and zero scores", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {-5.0, "negative"},
          {0.0, "zero"},
          {5.0, "positive"}
        ])

      result = ZsetStore.zrange(store, 0, "myzset", 0, -1)
      scores = Enum.map(result, fn {_member, score} -> score end)

      assert scores == [-5.0, 0.0, 5.0]
    end

    test "handles floating point scores", %{store: store} do
      :ok =
        ZsetStore.zadd(store, 0, "myzset", [
          {1.1, "a"},
          {1.2, "b"},
          {1.3, "c"}
        ])

      assert ZsetStore.zcard(store, 0, "myzset") == 3
    end
  end

  describe "large zset operations" do
    test "handles large sorted sets efficiently", %{store: store} do
      # Create a large zset
      large_zset = for i <- 1..1000, do: {i * 1.0, "member_#{i}"}

      :ok = ZsetStore.zadd(store, 0, "large_zset", large_zset)

      assert ZsetStore.zcard(store, 0, "large_zset") == 1000

      # Range query should work
      result = ZsetStore.zrange(store, 0, "large_zset", 0, 9)
      assert length(result) == 10

      # Score range query should work
      result = ZsetStore.zrangebyscore(store, 0, "large_zset", 100.0, 200.0)
      # 100 to 200 inclusive
      assert length(result) == 101
    end
  end
end
