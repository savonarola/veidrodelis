defmodule Vdr.MapProj.SetStoreTest do
  use ExUnit.Case, async: true

  alias Vdr.MapProj.{Sets, Common}

  setup do
    store = %{}

    {:ok, store: store}
  end

  describe "sadd/4" do
    test "adds members to a set", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a", "b", "c"])

      members = Sets.smembers(store, 0, "myset")
      assert Enum.sort(members) == ["a", "b", "c"]
    end

    test "adding duplicate members is idempotent", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a", "b"])
      store = Sets.sadd(store, 0, "myset", ["b", "c"])

      members = Sets.smembers(store, 0, "myset")
      assert Enum.sort(members) == ["a", "b", "c"]
    end

    test "supports multiple databases", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a", "b"])
      store = Sets.sadd(store, 1, "myset", ["x", "y"])

      members_db0 = Sets.smembers(store, 0, "myset")
      members_db1 = Sets.smembers(store, 1, "myset")

      assert Enum.sort(members_db0) == ["a", "b"]
      assert Enum.sort(members_db1) == ["x", "y"]
    end

    test "adds empty list of members", %{store: store} do
      store = Sets.sadd(store, 0, "myset", [])

      members = Sets.smembers(store, 0, "myset")
      assert members == []
    end
  end

  describe "srem/4" do
    test "removes members from a set", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a", "b", "c", "d"])
      store = Sets.srem(store, 0, "myset", ["b", "d"])

      members = Sets.smembers(store, 0, "myset")
      assert Enum.sort(members) == ["a", "c"]
    end

    test "removing non-existent members is safe", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a", "b"])
      store = Sets.srem(store, 0, "myset", ["c", "d"])

      members = Sets.smembers(store, 0, "myset")
      assert Enum.sort(members) == ["a", "b"]
    end

    test "removes all members and deletes key", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a", "b", "c"])
      store = Sets.srem(store, 0, "myset", ["a", "b", "c"])

      members = Sets.smembers(store, 0, "myset")
      assert members == []
      # Verify key was removed from store
      assert store == %{0 => %{}}
    end
  end

  describe "smove/5" do
    test "moves member from source to destination", %{store: store} do
      store = Sets.sadd(store, 0, "set1", ["a", "b", "c"])
      store = Sets.sadd(store, 0, "set2", ["x", "y"])

      store = Sets.smove(store, 0, "set1", "set2", "b")

      members_set1 = Sets.smembers(store, 0, "set1")
      members_set2 = Sets.smembers(store, 0, "set2")

      assert Enum.sort(members_set1) == ["a", "c"]
      assert Enum.sort(members_set2) == ["b", "x", "y"]
    end

    test "does nothing if member doesn't exist in source", %{store: store} do
      store = Sets.sadd(store, 0, "set1", ["a", "b"])
      store = Sets.sadd(store, 0, "set2", ["x", "y"])

      store = Sets.smove(store, 0, "set1", "set2", "z")

      members_set1 = Sets.smembers(store, 0, "set1")
      members_set2 = Sets.smembers(store, 0, "set2")

      assert Enum.sort(members_set1) == ["a", "b"]
      assert Enum.sort(members_set2) == ["x", "y"]
    end

    test "moves to non-existent destination set", %{store: store} do
      store = Sets.sadd(store, 0, "set1", ["a", "b"])

      store = Sets.smove(store, 0, "set1", "set2", "a")

      members_set1 = Sets.smembers(store, 0, "set1")
      members_set2 = Sets.smembers(store, 0, "set2")

      assert members_set1 == ["b"]
      assert members_set2 == ["a"]
    end

    test "handles moving from non-existent source", %{store: store} do
      store_before = store
      store = Sets.smove(store, 0, "nonexistent", "set2", "a")
      assert store == store_before
    end
  end

  describe "sunionstore/4" do
    test "stores union of multiple sets", %{store: store} do
      store = Sets.sadd(store, 0, "set1", ["a", "b", "c"])
      store = Sets.sadd(store, 0, "set2", ["c", "d", "e"])
      store = Sets.sadd(store, 0, "set3", ["e", "f"])

      store = Sets.sunionstore(store, 0, "result", ["set1", "set2", "set3"])

      members = Sets.smembers(store, 0, "result")
      assert Enum.sort(members) == ["a", "b", "c", "d", "e", "f"]
    end

    test "overwrites destination set", %{store: store} do
      store = Sets.sadd(store, 0, "set1", ["a", "b"])
      store = Sets.sadd(store, 0, "set2", ["c", "d"])
      store = Sets.sadd(store, 0, "result", ["x", "y", "z"])

      store = Sets.sunionstore(store, 0, "result", ["set1", "set2"])

      members = Sets.smembers(store, 0, "result")
      assert Enum.sort(members) == ["a", "b", "c", "d"]
    end

    test "handles non-existent source sets", %{store: store} do
      store = Sets.sadd(store, 0, "set1", ["a", "b"])

      store = Sets.sunionstore(store, 0, "result", ["set1", "nonexistent"])

      members = Sets.smembers(store, 0, "result")
      assert Enum.sort(members) == ["a", "b"]
    end

    test "handles empty source list", %{store: store} do
      store = Sets.sadd(store, 0, "result", ["x", "y"])

      store = Sets.sunionstore(store, 0, "result", [])

      members = Sets.smembers(store, 0, "result")
      assert members == []
    end

    test "can use destination as source", %{store: store} do
      store = Sets.sadd(store, 0, "set1", ["a", "b"])
      store = Sets.sadd(store, 0, "set2", ["c", "d"])

      store = Sets.sunionstore(store, 0, "set1", ["set1", "set2"])

      members = Sets.smembers(store, 0, "set1")
      assert Enum.sort(members) == ["a", "b", "c", "d"]
    end
  end

  describe "sinterstore/4" do
    test "stores intersection of multiple sets", %{store: store} do
      store = Sets.sadd(store, 0, "set1", ["a", "b", "c", "d"])
      store = Sets.sadd(store, 0, "set2", ["c", "d", "e", "f"])
      store = Sets.sadd(store, 0, "set3", ["c", "d", "g"])

      store = Sets.sinterstore(store, 0, "result", ["set1", "set2", "set3"])

      members = Sets.smembers(store, 0, "result")
      assert Enum.sort(members) == ["c", "d"]
    end

    test "empty result when no common elements", %{store: store} do
      store = Sets.sadd(store, 0, "set1", ["a", "b"])
      store = Sets.sadd(store, 0, "set2", ["c", "d"])

      store = Sets.sinterstore(store, 0, "result", ["set1", "set2"])

      members = Sets.smembers(store, 0, "result")
      assert members == []
    end

    test "empty result when any source is non-existent", %{store: store} do
      store = Sets.sadd(store, 0, "set1", ["a", "b", "c"])

      store = Sets.sinterstore(store, 0, "result", ["set1", "nonexistent"])

      members = Sets.smembers(store, 0, "result")
      assert members == []
    end

    test "overwrites destination set", %{store: store} do
      store = Sets.sadd(store, 0, "set1", ["a", "b", "c"])
      store = Sets.sadd(store, 0, "set2", ["b", "c", "d"])
      store = Sets.sadd(store, 0, "result", ["x", "y", "z"])

      store = Sets.sinterstore(store, 0, "result", ["set1", "set2"])

      members = Sets.smembers(store, 0, "result")
      assert Enum.sort(members) == ["b", "c"]
    end

    test "handles empty source list", %{store: store} do
      store = Sets.sinterstore(store, 0, "result", [])

      members = Sets.smembers(store, 0, "result")
      assert members == []
    end

    test "single set intersection returns that set", %{store: store} do
      store = Sets.sadd(store, 0, "set1", ["a", "b", "c"])

      store = Sets.sinterstore(store, 0, "result", ["set1"])

      members = Sets.smembers(store, 0, "result")
      assert Enum.sort(members) == ["a", "b", "c"]
    end
  end

  describe "sdiffstore/4" do
    test "stores difference of multiple sets", %{store: store} do
      store = Sets.sadd(store, 0, "set1", ["a", "b", "c", "d"])
      store = Sets.sadd(store, 0, "set2", ["c"])
      store = Sets.sadd(store, 0, "set3", ["a", "d"])

      store = Sets.sdiffstore(store, 0, "result", ["set1", "set2", "set3"])

      members = Sets.smembers(store, 0, "result")
      assert Enum.sort(members) == ["b"]
    end

    test "returns first set when subsequent sets are empty", %{store: store} do
      store = Sets.sadd(store, 0, "set1", ["a", "b", "c"])

      store = Sets.sdiffstore(store, 0, "result", ["set1", "nonexistent"])

      members = Sets.smembers(store, 0, "result")
      assert Enum.sort(members) == ["a", "b", "c"]
    end

    test "empty result when first set is subset of others", %{store: store} do
      store = Sets.sadd(store, 0, "set1", ["a", "b"])
      store = Sets.sadd(store, 0, "set2", ["a", "b", "c", "d"])

      store = Sets.sdiffstore(store, 0, "result", ["set1", "set2"])

      members = Sets.smembers(store, 0, "result")
      assert members == []
    end

    test "overwrites destination set", %{store: store} do
      store = Sets.sadd(store, 0, "set1", ["a", "b", "c"])
      store = Sets.sadd(store, 0, "set2", ["c", "d"])
      store = Sets.sadd(store, 0, "result", ["x", "y", "z"])

      store = Sets.sdiffstore(store, 0, "result", ["set1", "set2"])

      members = Sets.smembers(store, 0, "result")
      assert Enum.sort(members) == ["a", "b"]
    end

    test "handles empty source list", %{store: store} do
      store = Sets.sdiffstore(store, 0, "result", [])

      members = Sets.smembers(store, 0, "result")
      assert members == []
    end

    test "single set diff returns that set", %{store: store} do
      store = Sets.sadd(store, 0, "set1", ["a", "b", "c"])

      store = Sets.sdiffstore(store, 0, "result", ["set1"])

      members = Sets.smembers(store, 0, "result")
      assert Enum.sort(members) == ["a", "b", "c"]
    end
  end

  describe "smembers/3" do
    test "returns all members of a set", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["apple", "banana", "cherry"])

      members = Sets.smembers(store, 0, "myset")
      assert Enum.sort(members) == ["apple", "banana", "cherry"]
    end

    test "returns empty list for non-existent set", %{store: store} do
      members = Sets.smembers(store, 0, "nonexistent")
      assert members == []
    end

    test "returns empty list for empty set", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a"])
      store = Sets.srem(store, 0, "myset", ["a"])

      members = Sets.smembers(store, 0, "myset")
      assert members == []
    end
  end

  describe "sismember/4" do
    test "returns true when member exists", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a", "b", "c"])

      assert Sets.sismember(store, 0, "myset", "b") == true
    end

    test "returns false when member doesn't exist", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a", "b", "c"])

      assert Sets.sismember(store, 0, "myset", "d") == false
    end

    test "returns false for non-existent set", %{store: store} do
      assert Sets.sismember(store, 0, "nonexistent", "a") == false
    end
  end

  describe "scard/3" do
    test "returns the number of members in a set", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a", "b", "c", "d", "e"])

      assert Sets.scard(store, 0, "myset") == 5
    end

    test "returns 0 for non-existent set", %{store: store} do
      assert Sets.scard(store, 0, "nonexistent") == 0
    end

    test "returns 0 for empty set", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a"])
      store = Sets.srem(store, 0, "myset", ["a"])

      assert Sets.scard(store, 0, "myset") == 0
    end

    test "counts correctly with duplicates", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a", "b", "c"])
      # duplicates
      store = Sets.sadd(store, 0, "myset", ["a", "b", "c"])

      assert Sets.scard(store, 0, "myset") == 3
    end
  end

  describe "del/3" do
    test "deletes an entire set", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a", "b", "c"])
      assert Sets.scard(store, 0, "myset") == 3

      store = Common.del(store, 0, "myset")

      assert Sets.scard(store, 0, "myset") == 0
      assert Sets.smembers(store, 0, "myset") == []
    end

    test "handles deleting non-existent set", %{store: store} do
      store = Common.del(store, 0, "nonexistent")
      assert store == %{}
    end

    test "only deletes specified database and key", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a", "b"])
      store = Sets.sadd(store, 1, "myset", ["x", "y"])
      store = Sets.sadd(store, 0, "other", ["z"])

      store = Common.del(store, 0, "myset")

      assert Sets.scard(store, 0, "myset") == 0
      assert Sets.scard(store, 1, "myset") == 2
      assert Sets.scard(store, 0, "other") == 1
    end
  end

  describe "select_stream/4" do
    test "streams members matching filter function", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["apple", "banana", "cherry", "avocado"])

      # Filter function that matches "banana"
      filter_fun = fn member -> member == "banana" end

      result =
        store
        |> Sets.select_stream(0, "myset", filter_fun)
        |> Enum.to_list()

      assert ["banana"] = result
    end

    test "streams multiple matching members", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a", "b", "a1", "a2", "c"])

      # Filter function that matches "a1" or "a2"
      filter_fun = fn member -> member in ["a1", "a2"] end

      result =
        store
        |> Sets.select_stream(0, "myset", filter_fun)
        |> Enum.sort()

      assert ["a1", "a2"] = result
    end

    test "returns empty stream when no matches", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a", "b", "c"])

      # Filter function that matches "x"
      filter_fun = fn member -> member == "x" end

      result =
        store
        |> Sets.select_stream(0, "myset", filter_fun)
        |> Enum.to_list()

      assert [] = result
    end

    test "returns empty stream for non-existent set", %{store: store} do
      filter_fun = fn member -> member == "a" end

      result =
        store
        |> Sets.select_stream(0, "nonexistent", filter_fun)
        |> Enum.to_list()

      assert [] = result
    end

    test "works with match all filter", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a", "b", "c"])

      # Filter function that matches all members
      filter_fun = fn _member -> true end

      result =
        store
        |> Sets.select_stream(0, "myset", filter_fun)
        |> Enum.sort()

      assert ["a", "b", "c"] = result
    end

    test "streams lazily", %{store: store} do
      members = for i <- 1..100, do: "elem_#{String.pad_leading("#{i}", 3, "0")}"
      store = Sets.sadd(store, 0, "myset", members)

      # Match all and take only first 5
      filter_fun = fn _member -> true end

      result =
        store
        |> Sets.select_stream(0, "myset", filter_fun)
        |> Stream.take(5)
        |> Enum.to_list()

      assert length(result) == 5
    end
  end

  describe "select_rev_stream/4" do
    test "streams matching members in reverse order", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["apple", "banana", "cherry"])

      # Filter function that matches all members
      filter_fun = fn _member -> true end

      result =
        store
        |> Sets.select_rev_stream(0, "myset", filter_fun)
        |> Enum.to_list()

      forward_result =
        store
        |> Sets.select_stream(0, "myset", filter_fun)
        |> Enum.to_list()

      # Reverse stream should be reverse of forward stream
      assert result == Enum.reverse(forward_result)
    end

    test "returns empty stream when no matches", %{store: store} do
      store = Sets.sadd(store, 0, "myset", ["a", "b", "c"])

      # Filter function that matches "x"
      filter_fun = fn member -> member == "x" end

      result =
        store
        |> Sets.select_rev_stream(0, "myset", filter_fun)
        |> Enum.to_list()

      assert [] = result
    end

    test "returns empty stream for non-existent set", %{store: store} do
      filter_fun = fn member -> member == "a" end

      result =
        store
        |> Sets.select_rev_stream(0, "nonexistent", filter_fun)
        |> Enum.to_list()

      assert [] = result
    end

    test "streams lazily in reverse", %{store: store} do
      members = for i <- 1..100, do: "elem_#{String.pad_leading("#{i}", 3, "0")}"
      store = Sets.sadd(store, 0, "myset", members)

      # Match all and take only first 5 in reverse order
      filter_fun = fn _member -> true end

      result =
        store
        |> Sets.select_rev_stream(0, "myset", filter_fun)
        |> Stream.take(5)
        |> Enum.to_list()

      assert length(result) == 5
    end
  end

  describe "large set operations" do
    test "handles large sets efficiently", %{store: store} do
      # Create large sets
      large_set1 = for i <- 1..1000, do: "element_#{i}"
      large_set2 = for i <- 500..1500, do: "element_#{i}"

      store = Sets.sadd(store, 0, "large1", large_set1)
      store = Sets.sadd(store, 0, "large2", large_set2)

      assert Sets.scard(store, 0, "large1") == 1000
      assert Sets.scard(store, 0, "large2") == 1001

      # Union
      store = Sets.sunionstore(store, 0, "union", ["large1", "large2"])
      assert Sets.scard(store, 0, "union") == 1500

      # Intersection
      store = Sets.sinterstore(store, 0, "inter", ["large1", "large2"])
      # elements 500-1000
      assert Sets.scard(store, 0, "inter") == 501

      # Difference
      store = Sets.sdiffstore(store, 0, "diff", ["large1", "large2"])
      # elements 1-499
      assert Sets.scard(store, 0, "diff") == 499
    end
  end
end
