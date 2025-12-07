defmodule Vdr.MapProj.ZSetStoreTest do
  use ExUnit.Case, async: true

  alias Vdr.MapProj.{ZSets, Common}

  setup do
    # Simple decode function that returns members as-is
    config = ZSets.new(fn _key, member -> member end)
    store = %{}

    {:ok, config: config, store: store}
  end

  describe "new/1" do
    test "creates a ZSet store config with the given decode function" do
      decode_fun = fn _key, member -> member end
      config = ZSets.new(decode_fun)

      assert %Vdr.MapProj.ZSets{decode_fun: ^decode_fun} = config
    end
  end

  describe "zadd/5" do
    test "adds members with scores to a sorted set", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "myzset", [{1.0, "one"}, {2.0, "two"}])

      assert ZSets.zscore(store, 0, "myzset", "one") == 1.0
      assert ZSets.zscore(store, 0, "myzset", "two") == 2.0
    end

    test "updates existing member scores", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "myzset", [{1.0, "member"}])
      assert ZSets.zscore(store, 0, "myzset", "member") == 1.0

      store = ZSets.zadd(store, config, 0, "myzset", [{5.0, "member"}])
      assert ZSets.zscore(store, 0, "myzset", "member") == 5.0
      assert ZSets.zcard(store, 0, "myzset") == 1
    end

    test "supports multiple databases", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "myzset", [{1.0, "member"}])
      store = ZSets.zadd(store, config, 1, "myzset", [{2.0, "member"}])

      assert ZSets.zscore(store, 0, "myzset", "member") == 1.0
      assert ZSets.zscore(store, 1, "myzset", "member") == 2.0
    end

    test "adds multiple members at once", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      assert ZSets.zcard(store, 0, "myzset") == 3
    end

    test "adds empty list of members", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "myzset", [])

      assert ZSets.zcard(store, 0, "myzset") == 0
    end
  end

  describe "zadd_final/6" do
    test "adds a member with final score", %{config: config, store: store} do
      store = ZSets.zadd_final(store, config, 0, "myzset", 10.5, "member")

      assert ZSets.zscore(store, 0, "myzset", "member") == 10.5
    end
  end

  describe "zrem/5" do
    test "removes members from a sorted set", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      store = ZSets.zrem(store, config, 0, "myzset", ["two"])

      assert ZSets.zscore(store, 0, "myzset", "one") == 1.0
      assert ZSets.zscore(store, 0, "myzset", "two") == nil
      assert ZSets.zscore(store, 0, "myzset", "three") == 3.0
    end

    test "removing non-existent members is safe", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "myzset", [{1.0, "one"}])
      store = ZSets.zrem(store, config, 0, "myzset", ["nonexistent"])

      assert ZSets.zscore(store, 0, "myzset", "one") == 1.0
      assert ZSets.zcard(store, 0, "myzset") == 1
    end

    test "removes multiple members at once", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      store = ZSets.zrem(store, config, 0, "myzset", ["one", "three"])

      assert ZSets.zscore(store, 0, "myzset", "one") == nil
      assert ZSets.zscore(store, 0, "myzset", "two") == 2.0
      assert ZSets.zscore(store, 0, "myzset", "three") == nil
    end
  end

  describe "zremrangebyrank/5" do
    test "removes members by rank range", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"},
          {4.0, "four"},
          {5.0, "five"}
        ])

      store = ZSets.zremrangebyrank(store, 0, "myzset", 1, 3)

      assert ZSets.zcard(store, 0, "myzset") == 2
      assert ZSets.zscore(store, 0, "myzset", "one") == 1.0
      assert ZSets.zscore(store, 0, "myzset", "two") == nil
      assert ZSets.zscore(store, 0, "myzset", "three") == nil
      assert ZSets.zscore(store, 0, "myzset", "four") == nil
      assert ZSets.zscore(store, 0, "myzset", "five") == 5.0
    end

    test "supports negative rank indices", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      # Remove last element (rank -1)
      store = ZSets.zremrangebyrank(store, 0, "myzset", -1, -1)

      assert ZSets.zcard(store, 0, "myzset") == 2
      assert ZSets.zscore(store, 0, "myzset", "three") == nil
    end

    test "removes all members with full range", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      store = ZSets.zremrangebyrank(store, 0, "myzset", 0, -1)

      assert ZSets.zcard(store, 0, "myzset") == 0
    end
  end

  describe "zremrangebyscore/5" do
    test "removes members by score range", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"},
          {4.0, "four"},
          {5.0, "five"}
        ])

      store = ZSets.zremrangebyscore(store, 0, "myzset", 2.0, 4.0)

      assert ZSets.zcard(store, 0, "myzset") == 2
      assert ZSets.zscore(store, 0, "myzset", "one") == 1.0
      assert ZSets.zscore(store, 0, "myzset", "two") == nil
      assert ZSets.zscore(store, 0, "myzset", "five") == 5.0
    end

    test "supports unbounded ranges with infinity", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      store = ZSets.zremrangebyscore(store, 0, "myzset", :neg_inf, 2.0)

      assert ZSets.zcard(store, 0, "myzset") == 1
      assert ZSets.zscore(store, 0, "myzset", "three") == 3.0
    end
  end

  describe "zremrangebylex/5" do
    test "removes members by lexicographical range", %{config: config, store: store} do
      # All members with same score for lex ordering
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {0.0, "apple"},
          {0.0, "banana"},
          {0.0, "cherry"},
          {0.0, "date"}
        ])

      store = ZSets.zremrangebylex(store, 0, "myzset", "banana", "cherry")

      assert ZSets.zcard(store, 0, "myzset") == 2
      assert ZSets.zscore(store, 0, "myzset", "apple") == 0.0
      assert ZSets.zscore(store, 0, "myzset", "banana") == nil
      assert ZSets.zscore(store, 0, "myzset", "cherry") == nil
      assert ZSets.zscore(store, 0, "myzset", "date") == 0.0
    end
  end

  describe "zpopmin/4" do
    test "removes and returns member with lowest score", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {3.0, "three"},
          {1.0, "one"},
          {2.0, "two"}
        ])

      {store, result} = ZSets.zpopmin(store, 0, "myzset")

      assert result == [{"one", 1.0}]
      assert ZSets.zcard(store, 0, "myzset") == 2
      assert ZSets.zscore(store, 0, "myzset", "one") == nil
    end

    test "removes and returns multiple members with lowest scores", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"},
          {4.0, "four"}
        ])

      {store, result} = ZSets.zpopmin(store, 0, "myzset", 2)

      assert result == [{"one", 1.0}, {"two", 2.0}]
      assert ZSets.zcard(store, 0, "myzset") == 2
    end

    test "returns empty list for non-existent zset", %{store: store} do
      {_store, result} = ZSets.zpopmin(store, 0, "nonexistent")

      assert result == []
    end
  end

  describe "zpopmax/4" do
    test "removes and returns member with highest score", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {3.0, "three"},
          {1.0, "one"},
          {2.0, "two"}
        ])

      {store, result} = ZSets.zpopmax(store, 0, "myzset")

      assert result == [{"three", 3.0}]
      assert ZSets.zcard(store, 0, "myzset") == 2
      assert ZSets.zscore(store, 0, "myzset", "three") == nil
    end

    test "removes and returns multiple members with highest scores", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"},
          {4.0, "four"}
        ])

      {store, result} = ZSets.zpopmax(store, 0, "myzset", 2)

      assert result == [{"four", 4.0}, {"three", 3.0}]
      assert ZSets.zcard(store, 0, "myzset") == 2
    end
  end

  describe "zunionstore/6" do
    test "computes union of two sorted sets with default weights and sum", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "zset1", [{1.0, "a"}, {2.0, "b"}])
      store = ZSets.zadd(store, config, 0, "zset2", [{1.0, "b"}, {2.0, "c"}])

      store = ZSets.zunionstore(store, 0, "dest", ["zset1", "zset2"])

      assert ZSets.zcard(store, 0, "dest") == 3
      assert ZSets.zscore(store, 0, "dest", "a") == 1.0
      # 2.0 + 1.0
      assert ZSets.zscore(store, 0, "dest", "b") == 3.0
      assert ZSets.zscore(store, 0, "dest", "c") == 2.0
    end

    test "computes union with weights", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "zset1", [{1.0, "a"}, {2.0, "b"}])
      store = ZSets.zadd(store, config, 0, "zset2", [{1.0, "b"}, {2.0, "c"}])

      store = ZSets.zunionstore(store, 0, "dest", ["zset1", "zset2"], [2.0, 3.0])

      # 1.0 * 2
      assert ZSets.zscore(store, 0, "dest", "a") == 2.0
      # 2.0 * 2 + 1.0 * 3
      assert ZSets.zscore(store, 0, "dest", "b") == 7.0
      # 2.0 * 3
      assert ZSets.zscore(store, 0, "dest", "c") == 6.0
    end

    test "computes union with MIN aggregate", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "zset1", [{5.0, "a"}, {2.0, "b"}])
      store = ZSets.zadd(store, config, 0, "zset2", [{3.0, "a"}, {4.0, "b"}])

      store = ZSets.zunionstore(store, 0, "dest", ["zset1", "zset2"], [], :min)

      assert ZSets.zscore(store, 0, "dest", "a") == 3.0
      assert ZSets.zscore(store, 0, "dest", "b") == 2.0
    end

    test "computes union with MAX aggregate", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "zset1", [{5.0, "a"}, {2.0, "b"}])
      store = ZSets.zadd(store, config, 0, "zset2", [{3.0, "a"}, {4.0, "b"}])

      store = ZSets.zunionstore(store, 0, "dest", ["zset1", "zset2"], [], :max)

      assert ZSets.zscore(store, 0, "dest", "a") == 5.0
      assert ZSets.zscore(store, 0, "dest", "b") == 4.0
    end

    test "overwrites existing destination", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "zset1", [{1.0, "a"}])
      store = ZSets.zadd(store, config, 0, "dest", [{99.0, "old"}])

      store = ZSets.zunionstore(store, 0, "dest", ["zset1"])

      assert ZSets.zcard(store, 0, "dest") == 1
      assert ZSets.zscore(store, 0, "dest", "a") == 1.0
      assert ZSets.zscore(store, 0, "dest", "old") == nil
    end
  end

  describe "zinterstore/6" do
    test "computes intersection of two sorted sets with default weights and sum", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "zset1", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}])
      store = ZSets.zadd(store, config, 0, "zset2", [{1.0, "b"}, {2.0, "c"}, {3.0, "d"}])

      store = ZSets.zinterstore(store, 0, "dest", ["zset1", "zset2"])

      assert ZSets.zcard(store, 0, "dest") == 2
      assert ZSets.zscore(store, 0, "dest", "a") == nil
      # 2.0 + 1.0
      assert ZSets.zscore(store, 0, "dest", "b") == 3.0
      # 3.0 + 2.0
      assert ZSets.zscore(store, 0, "dest", "c") == 5.0
      assert ZSets.zscore(store, 0, "dest", "d") == nil
    end

    test "computes intersection with weights", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "zset1", [{1.0, "a"}, {2.0, "b"}])
      store = ZSets.zadd(store, config, 0, "zset2", [{1.0, "b"}, {2.0, "c"}])

      store = ZSets.zinterstore(store, 0, "dest", ["zset1", "zset2"], [2.0, 3.0])

      assert ZSets.zcard(store, 0, "dest") == 1
      # 2.0 * 2 + 1.0 * 3
      assert ZSets.zscore(store, 0, "dest", "b") == 7.0
    end

    test "computes intersection with MIN aggregate", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "zset1", [{5.0, "a"}, {2.0, "b"}])
      store = ZSets.zadd(store, config, 0, "zset2", [{3.0, "a"}, {4.0, "b"}])

      store = ZSets.zinterstore(store, 0, "dest", ["zset1", "zset2"], [], :min)

      assert ZSets.zscore(store, 0, "dest", "a") == 3.0
      assert ZSets.zscore(store, 0, "dest", "b") == 2.0
    end

    test "computes intersection with MAX aggregate", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "zset1", [{5.0, "a"}, {2.0, "b"}])
      store = ZSets.zadd(store, config, 0, "zset2", [{3.0, "a"}, {4.0, "b"}])

      store = ZSets.zinterstore(store, 0, "dest", ["zset1", "zset2"], [], :max)

      assert ZSets.zscore(store, 0, "dest", "a") == 5.0
      assert ZSets.zscore(store, 0, "dest", "b") == 4.0
    end

    test "returns empty set when no common members", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "zset1", [{1.0, "a"}])
      store = ZSets.zadd(store, config, 0, "zset2", [{1.0, "b"}])

      store = ZSets.zinterstore(store, 0, "dest", ["zset1", "zset2"])

      assert ZSets.zcard(store, 0, "dest") == 0
    end
  end

  describe "zscore/4" do
    test "gets score for existing member", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "myzset", [{42.5, "member"}])

      assert ZSets.zscore(store, 0, "myzset", "member") == 42.5
    end

    test "returns nil for non-existent member", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "myzset", [{1.0, "member"}])

      assert ZSets.zscore(store, 0, "myzset", "nonexistent") == nil
    end

    test "returns nil for non-existent zset", %{store: store} do
      assert ZSets.zscore(store, 0, "nonexistent", "member") == nil
    end
  end

  describe "zcard/3" do
    test "returns the number of members in a sorted set", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      assert ZSets.zcard(store, 0, "myzset") == 3
    end

    test "returns 0 for non-existent zset", %{store: store} do
      assert ZSets.zcard(store, 0, "nonexistent") == 0
    end

    test "counts correctly with updates", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "myzset", [{1.0, "member"}])
      store = ZSets.zadd(store, config, 0, "myzset", [{5.0, "member"}])

      assert ZSets.zcard(store, 0, "myzset") == 1
    end
  end

  describe "zrange/5" do
    test "returns members in score order", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {3.0, "three"},
          {1.0, "one"},
          {2.0, "two"}
        ])

      result = ZSets.zrange(store, 0, "myzset", 0, 2)

      assert result == [{"one", 1.0}, {"two", 2.0}, {"three", 3.0}]
    end

    test "returns subset by rank range", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"},
          {4.0, "four"}
        ])

      result = ZSets.zrange(store, 0, "myzset", 1, 2)

      assert result == [{"two", 2.0}, {"three", 3.0}]
    end

    test "supports negative rank indices", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      result = ZSets.zrange(store, 0, "myzset", -2, -1)

      assert result == [{"two", 2.0}, {"three", 3.0}]
    end

    test "returns empty list for non-existent zset", %{store: store} do
      result = ZSets.zrange(store, 0, "nonexistent", 0, -1)

      assert result == []
    end
  end

  describe "zrangebyscore/5" do
    test "returns members in score range", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"},
          {4.0, "four"},
          {5.0, "five"}
        ])

      result = ZSets.zrangebyscore(store, 0, "myzset", 2.0, 4.0)

      assert length(result) == 3
      assert Enum.map(result, fn {_member, score} -> score end) == [2.0, 3.0, 4.0]
    end

    test "supports unbounded ranges", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"},
          {3.0, "three"}
        ])

      result = ZSets.zrangebyscore(store, 0, "myzset", :neg_inf, 2.0)

      assert length(result) == 2
    end
  end

  describe "select_stream/3" do
    test "returns stream of members in score order", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {3.0, "three"},
          {1.0, "one"},
          {2.0, "two"}
        ])

      result =
        store
        |> ZSets.select_stream(0, "myzset")
        |> Enum.to_list()

      assert result == [{"one", 1.0}, {"two", 2.0}, {"three", 3.0}]
    end

    test "returns empty stream for non-existent zset", %{store: store} do
      result =
        store
        |> ZSets.select_stream(0, "nonexistent")
        |> Enum.to_list()

      assert result == []
    end
  end

  describe "select_rev_stream/3" do
    test "returns stream of members in reverse score order", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {3.0, "three"},
          {1.0, "one"},
          {2.0, "two"}
        ])

      result =
        store
        |> ZSets.select_rev_stream(0, "myzset")
        |> Enum.to_list()

      assert result == [{"three", 3.0}, {"two", 2.0}, {"one", 1.0}]
    end

    test "returns empty stream for non-existent zset", %{store: store} do
      result =
        store
        |> ZSets.select_rev_stream(0, "nonexistent")
        |> Enum.to_list()

      assert result == []
    end
  end

  describe "del/3" do
    test "deletes an entire sorted set", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.0, "one"},
          {2.0, "two"}
        ])

      assert ZSets.zcard(store, 0, "myzset") == 2

      store = Common.del(store, 0, "myzset")

      assert ZSets.zcard(store, 0, "myzset") == 0
    end

    test "handles deleting non-existent zset", %{store: store} do
      store = Common.del(store, 0, "nonexistent")
      assert store == %{}
    end

    test "only deletes specified database and key", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "myzset", [{1.0, "one"}])
      store = ZSets.zadd(store, config, 1, "myzset", [{1.0, "one"}])
      store = ZSets.zadd(store, config, 0, "other", [{1.0, "one"}])

      store = Common.del(store, 0, "myzset")

      assert ZSets.zcard(store, 0, "myzset") == 0
      assert ZSets.zcard(store, 1, "myzset") == 1
      assert ZSets.zcard(store, 0, "other") == 1
    end
  end

  describe "decode function" do
    test "uses custom decode function for member values" do
      # Decode function that converts to uppercase for case-insensitive storage
      decode_fun = fn _key, member -> String.upcase(member) end
      config = ZSets.new(decode_fun)
      store = %{}

      store = ZSets.zadd(store, config, 0, "myzset", [{1.0, "apple"}, {2.0, "BANANA"}])

      # Members are stored by their decoded (uppercased) keys
      result = ZSets.zrange(store, 0, "myzset", 0, 1)
      decoded_members = Enum.map(result, fn {member, _score} -> member end)

      assert Enum.sort(decoded_members) == ["APPLE", "BANANA"]

      # Setting "APPLE" again should update (same decoded member)
      store = ZSets.zadd(store, config, 0, "myzset", [{5.0, "APPLE"}])
      assert ZSets.zcard(store, 0, "myzset") == 2
      assert ZSets.zscore(store, 0, "myzset", "APPLE") == 5.0
    end

    test "decode function receives key for context" do
      # Decode function that includes key prefix
      decode_fun = fn key, member -> {key, member} end
      config = ZSets.new(decode_fun)
      store = %{}

      store = ZSets.zadd(store, config, 0, "zset1", [{1.0, "member"}])
      store = ZSets.zadd(store, config, 0, "zset2", [{2.0, "member"}])

      score1 = ZSets.zscore(store, 0, "zset1", {"zset1", "member"})
      score2 = ZSets.zscore(store, 0, "zset2", {"zset2", "member"})

      # Decoded members include the key
      assert score1 == 1.0
      assert score2 == 2.0
    end
  end

  describe "dual structure synchronization" do
    test "both entries and index are kept in sync on add", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "myzset", [{1.0, "member"}])

      # Verify score lookup works (uses entries)
      assert ZSets.zscore(store, 0, "myzset", "member") == 1.0

      # Verify range query works (uses index)
      result = ZSets.zrangebyscore(store, 0, "myzset", 0.0, 2.0)
      assert length(result) == 1
    end

    test "both entries and index are kept in sync on update", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "myzset", [{1.0, "member"}])
      store = ZSets.zadd(store, config, 0, "myzset", [{5.0, "member"}])

      # Old score should be gone
      result_old = ZSets.zrangebyscore(store, 0, "myzset", 0.0, 2.0)
      assert length(result_old) == 0

      # New score should be in both structures
      assert ZSets.zscore(store, 0, "myzset", "member") == 5.0
      result_new = ZSets.zrangebyscore(store, 0, "myzset", 4.0, 6.0)
      assert length(result_new) == 1
    end

    test "both entries and index are removed on delete", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "myzset", [{1.0, "member"}])
      store = ZSets.zrem(store, config, 0, "myzset", ["member"])

      # Both lookups should fail
      assert ZSets.zscore(store, 0, "myzset", "member") == nil
      result = ZSets.zrangebyscore(store, 0, "myzset", 0.0, 2.0)
      assert length(result) == 0
    end
  end

  describe "edge cases" do
    test "handles empty member names", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "myzset", [{1.0, ""}])

      assert ZSets.zscore(store, 0, "myzset", "") == 1.0
    end

    test "handles binary member names", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "myzset", [{1.0, <<1, 2, 3>>}])

      assert ZSets.zscore(store, 0, "myzset", <<1, 2, 3>>) == 1.0
    end

    test "handles same score for multiple members", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.0, "a"},
          {1.0, "b"},
          {1.0, "c"}
        ])

      result = ZSets.zrangebyscore(store, 0, "myzset", 1.0, 1.0)
      assert length(result) == 3
      assert Enum.all?(result, fn {_member, score} -> score == 1.0 end)
    end

    test "handles negative and zero scores", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {-5.0, "negative"},
          {0.0, "zero"},
          {5.0, "positive"}
        ])

      result = ZSets.zrange(store, 0, "myzset", 0, -1)
      scores = Enum.map(result, fn {_member, score} -> score end)

      assert scores == [-5.0, 0.0, 5.0]
    end

    test "handles floating point scores", %{config: config, store: store} do
      store =
        ZSets.zadd(store, config, 0, "myzset", [
          {1.1, "a"},
          {1.2, "b"},
          {1.3, "c"}
        ])

      assert ZSets.zcard(store, 0, "myzset") == 3
    end
  end

  describe "large zset operations" do
    test "handles large sorted sets efficiently", %{config: config, store: store} do
      # Create a large zset
      large_zset = for i <- 1..1000, do: {i * 1.0, "member_#{i}"}

      store = ZSets.zadd(store, config, 0, "large_zset", large_zset)

      assert ZSets.zcard(store, 0, "large_zset") == 1000

      # Range query should work
      result = ZSets.zrange(store, 0, "large_zset", 0, 9)
      assert length(result) == 10

      # Score range query should work
      result = ZSets.zrangebyscore(store, 0, "large_zset", 100.0, 200.0)
      # 100 to 200 inclusive
      assert length(result) == 101
    end
  end

  describe "empty zset cleanup" do
    test "removes key when all members are removed", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "myzset", [{1.0, "one"}])
      store = ZSets.zrem(store, config, 0, "myzset", ["one"])

      # Key should be removed from db_map
      assert store == %{0 => %{}}
    end

    test "removes key when popping last member", %{config: config, store: store} do
      store = ZSets.zadd(store, config, 0, "myzset", [{1.0, "one"}])
      {store, _result} = ZSets.zpopmin(store, 0, "myzset")

      # Key should be removed from db_map
      assert store == %{0 => %{}}
    end
  end
end
