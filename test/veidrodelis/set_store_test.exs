defmodule Veidrodelis.SetStoreTest do
  use ExUnit.Case, async: true

  alias Veidrodelis.SetStore

  setup do
    # Simple decode function that returns the element as-is
    decode_fun = fn _key, element -> element end

    store = SetStore.new(decode_fun)

    {:ok, store: store}
  end

  describe "new/1" do
    test "creates a new ETS table and returns a struct" do
      decode_fun = fn _key, element -> element end
      store = SetStore.new(decode_fun)

      assert %SetStore{tid: tid, decode_fun: ^decode_fun} = store
      assert is_reference(tid)
      assert :ets.info(tid) != :undefined

      # Clean up
      SetStore.destroy(store)
    end
  end

  describe "sadd/4" do
    test "adds members to a set", %{store: store} do
      :ok = SetStore.sadd(store, 0, "myset", ["a", "b", "c"])

      members = SetStore.smembers(store, 0, "myset")
      assert Enum.sort(members) == ["a", "b", "c"]
    end

    test "adding duplicate members is idempotent", %{store: store} do
      :ok = SetStore.sadd(store, 0, "myset", ["a", "b"])
      :ok = SetStore.sadd(store, 0, "myset", ["b", "c"])

      members = SetStore.smembers(store, 0, "myset")
      assert Enum.sort(members) == ["a", "b", "c"]
    end

    test "supports multiple databases", %{store: store} do
      :ok = SetStore.sadd(store, 0, "myset", ["a", "b"])
      :ok = SetStore.sadd(store, 1, "myset", ["x", "y"])

      members_db0 = SetStore.smembers(store, 0, "myset")
      members_db1 = SetStore.smembers(store, 1, "myset")

      assert Enum.sort(members_db0) == ["a", "b"]
      assert Enum.sort(members_db1) == ["x", "y"]
    end

    test "adds empty list of members", %{store: store} do
      :ok = SetStore.sadd(store, 0, "myset", [])

      members = SetStore.smembers(store, 0, "myset")
      assert members == []
    end
  end

  describe "srem/4" do
    test "removes members from a set", %{store: store} do
      :ok = SetStore.sadd(store, 0, "myset", ["a", "b", "c", "d"])
      :ok = SetStore.srem(store, 0, "myset", ["b", "d"])

      members = SetStore.smembers(store, 0, "myset")
      assert Enum.sort(members) == ["a", "c"]
    end

    test "removing non-existent members is safe", %{store: store} do
      :ok = SetStore.sadd(store, 0, "myset", ["a", "b"])
      :ok = SetStore.srem(store, 0, "myset", ["c", "d"])

      members = SetStore.smembers(store, 0, "myset")
      assert Enum.sort(members) == ["a", "b"]
    end

    test "removes all members", %{store: store} do
      :ok = SetStore.sadd(store, 0, "myset", ["a", "b", "c"])
      :ok = SetStore.srem(store, 0, "myset", ["a", "b", "c"])

      members = SetStore.smembers(store, 0, "myset")
      assert members == []
    end
  end

  describe "smove/5" do
    test "moves member from source to destination", %{store: store} do
      :ok = SetStore.sadd(store, 0, "set1", ["a", "b", "c"])
      :ok = SetStore.sadd(store, 0, "set2", ["x", "y"])

      assert :ok = SetStore.smove(store, 0, "set1", "set2", "b")

      members_set1 = SetStore.smembers(store, 0, "set1")
      members_set2 = SetStore.smembers(store, 0, "set2")

      assert Enum.sort(members_set1) == ["a", "c"]
      assert Enum.sort(members_set2) == ["b", "x", "y"]
    end

    test "returns :not_found if member doesn't exist in source", %{store: store} do
      :ok = SetStore.sadd(store, 0, "set1", ["a", "b"])
      :ok = SetStore.sadd(store, 0, "set2", ["x", "y"])

      assert :not_found = SetStore.smove(store, 0, "set1", "set2", "z")

      members_set1 = SetStore.smembers(store, 0, "set1")
      members_set2 = SetStore.smembers(store, 0, "set2")

      assert Enum.sort(members_set1) == ["a", "b"]
      assert Enum.sort(members_set2) == ["x", "y"]
    end

    test "moves to non-existent destination set", %{store: store} do
      :ok = SetStore.sadd(store, 0, "set1", ["a", "b"])

      assert :ok = SetStore.smove(store, 0, "set1", "set2", "a")

      members_set1 = SetStore.smembers(store, 0, "set1")
      members_set2 = SetStore.smembers(store, 0, "set2")

      assert members_set1 == ["b"]
      assert members_set2 == ["a"]
    end

    test "handles moving from non-existent source", %{store: store} do
      assert :not_found = SetStore.smove(store, 0, "nonexistent", "set2", "a")
    end
  end

  describe "sunionstore/4" do
    test "stores union of multiple sets", %{store: store} do
      :ok = SetStore.sadd(store, 0, "set1", ["a", "b", "c"])
      :ok = SetStore.sadd(store, 0, "set2", ["c", "d", "e"])
      :ok = SetStore.sadd(store, 0, "set3", ["e", "f"])

      :ok = SetStore.sunionstore(store, 0, "result", ["set1", "set2", "set3"])

      members = SetStore.smembers(store, 0, "result")
      assert Enum.sort(members) == ["a", "b", "c", "d", "e", "f"]
    end

    test "overwrites destination set", %{store: store} do
      :ok = SetStore.sadd(store, 0, "set1", ["a", "b"])
      :ok = SetStore.sadd(store, 0, "set2", ["c", "d"])
      :ok = SetStore.sadd(store, 0, "result", ["x", "y", "z"])

      :ok = SetStore.sunionstore(store, 0, "result", ["set1", "set2"])

      members = SetStore.smembers(store, 0, "result")
      assert Enum.sort(members) == ["a", "b", "c", "d"]
    end

    test "handles non-existent source sets", %{store: store} do
      :ok = SetStore.sadd(store, 0, "set1", ["a", "b"])

      :ok = SetStore.sunionstore(store, 0, "result", ["set1", "nonexistent"])

      members = SetStore.smembers(store, 0, "result")
      assert Enum.sort(members) == ["a", "b"]
    end

    test "handles empty source list", %{store: store} do
      :ok = SetStore.sadd(store, 0, "result", ["x", "y"])

      :ok = SetStore.sunionstore(store, 0, "result", [])

      members = SetStore.smembers(store, 0, "result")
      assert members == []
    end

    test "can use destination as source", %{store: store} do
      :ok = SetStore.sadd(store, 0, "set1", ["a", "b"])
      :ok = SetStore.sadd(store, 0, "set2", ["c", "d"])

      :ok = SetStore.sunionstore(store, 0, "set1", ["set1", "set2"])

      members = SetStore.smembers(store, 0, "set1")
      assert Enum.sort(members) == ["a", "b", "c", "d"]
    end
  end

  describe "sinterstore/4" do
    test "stores intersection of multiple sets", %{store: store} do
      :ok = SetStore.sadd(store, 0, "set1", ["a", "b", "c", "d"])
      :ok = SetStore.sadd(store, 0, "set2", ["c", "d", "e", "f"])
      :ok = SetStore.sadd(store, 0, "set3", ["c", "d", "g"])

      :ok = SetStore.sinterstore(store, 0, "result", ["set1", "set2", "set3"])

      members = SetStore.smembers(store, 0, "result")
      assert Enum.sort(members) == ["c", "d"]
    end

    test "empty result when no common elements", %{store: store} do
      :ok = SetStore.sadd(store, 0, "set1", ["a", "b"])
      :ok = SetStore.sadd(store, 0, "set2", ["c", "d"])

      :ok = SetStore.sinterstore(store, 0, "result", ["set1", "set2"])

      members = SetStore.smembers(store, 0, "result")
      assert members == []
    end

    test "empty result when any source is non-existent", %{store: store} do
      :ok = SetStore.sadd(store, 0, "set1", ["a", "b", "c"])

      :ok = SetStore.sinterstore(store, 0, "result", ["set1", "nonexistent"])

      members = SetStore.smembers(store, 0, "result")
      assert members == []
    end

    test "overwrites destination set", %{store: store} do
      :ok = SetStore.sadd(store, 0, "set1", ["a", "b", "c"])
      :ok = SetStore.sadd(store, 0, "set2", ["b", "c", "d"])
      :ok = SetStore.sadd(store, 0, "result", ["x", "y", "z"])

      :ok = SetStore.sinterstore(store, 0, "result", ["set1", "set2"])

      members = SetStore.smembers(store, 0, "result")
      assert Enum.sort(members) == ["b", "c"]
    end

    test "handles empty source list", %{store: store} do
      :ok = SetStore.sinterstore(store, 0, "result", [])

      members = SetStore.smembers(store, 0, "result")
      assert members == []
    end

    test "single set intersection returns that set", %{store: store} do
      :ok = SetStore.sadd(store, 0, "set1", ["a", "b", "c"])

      :ok = SetStore.sinterstore(store, 0, "result", ["set1"])

      members = SetStore.smembers(store, 0, "result")
      assert Enum.sort(members) == ["a", "b", "c"]
    end
  end

  describe "sdiffstore/4" do
    test "stores difference of multiple sets", %{store: store} do
      :ok = SetStore.sadd(store, 0, "set1", ["a", "b", "c", "d"])
      :ok = SetStore.sadd(store, 0, "set2", ["c"])
      :ok = SetStore.sadd(store, 0, "set3", ["a", "d"])

      :ok = SetStore.sdiffstore(store, 0, "result", ["set1", "set2", "set3"])

      members = SetStore.smembers(store, 0, "result")
      assert Enum.sort(members) == ["b"]
    end

    test "returns first set when subsequent sets are empty", %{store: store} do
      :ok = SetStore.sadd(store, 0, "set1", ["a", "b", "c"])

      :ok = SetStore.sdiffstore(store, 0, "result", ["set1", "nonexistent"])

      members = SetStore.smembers(store, 0, "result")
      assert Enum.sort(members) == ["a", "b", "c"]
    end

    test "empty result when first set is subset of others", %{store: store} do
      :ok = SetStore.sadd(store, 0, "set1", ["a", "b"])
      :ok = SetStore.sadd(store, 0, "set2", ["a", "b", "c", "d"])

      :ok = SetStore.sdiffstore(store, 0, "result", ["set1", "set2"])

      members = SetStore.smembers(store, 0, "result")
      assert members == []
    end

    test "overwrites destination set", %{store: store} do
      :ok = SetStore.sadd(store, 0, "set1", ["a", "b", "c"])
      :ok = SetStore.sadd(store, 0, "set2", ["c", "d"])
      :ok = SetStore.sadd(store, 0, "result", ["x", "y", "z"])

      :ok = SetStore.sdiffstore(store, 0, "result", ["set1", "set2"])

      members = SetStore.smembers(store, 0, "result")
      assert Enum.sort(members) == ["a", "b"]
    end

    test "handles empty source list", %{store: store} do
      :ok = SetStore.sdiffstore(store, 0, "result", [])

      members = SetStore.smembers(store, 0, "result")
      assert members == []
    end

    test "single set diff returns that set", %{store: store} do
      :ok = SetStore.sadd(store, 0, "set1", ["a", "b", "c"])

      :ok = SetStore.sdiffstore(store, 0, "result", ["set1"])

      members = SetStore.smembers(store, 0, "result")
      assert Enum.sort(members) == ["a", "b", "c"]
    end
  end

  describe "smembers/3" do
    test "returns all members of a set", %{store: store} do
      :ok = SetStore.sadd(store, 0, "myset", ["apple", "banana", "cherry"])

      members = SetStore.smembers(store, 0, "myset")
      assert Enum.sort(members) == ["apple", "banana", "cherry"]
    end

    test "returns empty list for non-existent set", %{store: store} do
      members = SetStore.smembers(store, 0, "nonexistent")
      assert members == []
    end

    test "returns empty list for empty set", %{store: store} do
      :ok = SetStore.sadd(store, 0, "myset", ["a"])
      :ok = SetStore.srem(store, 0, "myset", ["a"])

      members = SetStore.smembers(store, 0, "myset")
      assert members == []
    end
  end

  describe "sismember/4" do
    test "returns true when member exists", %{store: store} do
      :ok = SetStore.sadd(store, 0, "myset", ["a", "b", "c"])

      assert SetStore.sismember(store, 0, "myset", "b") == true
    end

    test "returns false when member doesn't exist", %{store: store} do
      :ok = SetStore.sadd(store, 0, "myset", ["a", "b", "c"])

      assert SetStore.sismember(store, 0, "myset", "d") == false
    end

    test "returns false for non-existent set", %{store: store} do
      assert SetStore.sismember(store, 0, "nonexistent", "a") == false
    end
  end

  describe "scard/3" do
    test "returns the number of members in a set", %{store: store} do
      :ok = SetStore.sadd(store, 0, "myset", ["a", "b", "c", "d", "e"])

      assert SetStore.scard(store, 0, "myset") == 5
    end

    test "returns 0 for non-existent set", %{store: store} do
      assert SetStore.scard(store, 0, "nonexistent") == 0
    end

    test "returns 0 for empty set", %{store: store} do
      :ok = SetStore.sadd(store, 0, "myset", ["a"])
      :ok = SetStore.srem(store, 0, "myset", ["a"])

      assert SetStore.scard(store, 0, "myset") == 0
    end

    test "counts correctly with duplicates", %{store: store} do
      :ok = SetStore.sadd(store, 0, "myset", ["a", "b", "c"])
      # duplicates
      :ok = SetStore.sadd(store, 0, "myset", ["a", "b", "c"])

      assert SetStore.scard(store, 0, "myset") == 3
    end
  end

  describe "del/3" do
    test "deletes an entire set", %{store: store} do
      :ok = SetStore.sadd(store, 0, "myset", ["a", "b", "c"])
      assert SetStore.scard(store, 0, "myset") == 3

      :ok = SetStore.del(store, 0, "myset")

      assert SetStore.scard(store, 0, "myset") == 0
      assert SetStore.smembers(store, 0, "myset") == []
    end

    test "handles deleting non-existent set", %{store: store} do
      :ok = SetStore.del(store, 0, "nonexistent")
    end

    test "only deletes specified database and key", %{store: store} do
      :ok = SetStore.sadd(store, 0, "myset", ["a", "b"])
      :ok = SetStore.sadd(store, 1, "myset", ["x", "y"])
      :ok = SetStore.sadd(store, 0, "other", ["z"])

      :ok = SetStore.del(store, 0, "myset")

      assert SetStore.scard(store, 0, "myset") == 0
      assert SetStore.scard(store, 1, "myset") == 2
      assert SetStore.scard(store, 0, "other") == 1
    end
  end

  describe "decode function" do
    test "uses custom decode function for ordering" do
      # Decode function that converts to uppercase for case-insensitive ordering
      decode_fun = fn _key, element -> String.upcase(element) end

      store = SetStore.new(decode_fun)

      :ok = SetStore.sadd(store, 0, "myset", ["apple", "BANANA", "Cherry"])

      members = SetStore.smembers(store, 0, "myset")
      # Members are stored by their decoded (uppercased) keys
      assert Enum.sort(members) == ["APPLE", "BANANA", "CHERRY"]

      # Adding "APPLE" again should be idempotent (same decoded value)
      :ok = SetStore.sadd(store, 0, "myset", ["APPLE"])
      assert SetStore.scard(store, 0, "myset") == 3

      # Clean up
      SetStore.destroy(store)
    end

    test "decode function receives key for context" do
      # Decode function that includes key prefix
      decode_fun = fn key, element -> {key, element} end

      store = SetStore.new(decode_fun)

      :ok = SetStore.sadd(store, 0, "set1", ["a", "b"])
      :ok = SetStore.sadd(store, 0, "set2", ["a", "b"])

      members_set1 = SetStore.smembers(store, 0, "set1")
      members_set2 = SetStore.smembers(store, 0, "set2")

      # Decoded values include the key, so they're different
      assert Enum.sort(members_set1) == [{"set1", "a"}, {"set1", "b"}]
      assert Enum.sort(members_set2) == [{"set2", "a"}, {"set2", "b"}]

      # Clean up
      SetStore.destroy(store)
    end

    test "numeric decode function for integer-like strings" do
      # Decode function that converts strings to integers for numeric ordering
      decode_fun = fn _key, element ->
        case Integer.parse(element) do
          {num, ""} -> num
          _ -> element
        end
      end

      store = SetStore.new(decode_fun)

      :ok = SetStore.sadd(store, 0, "numbers", ["10", "2", "100", "20"])

      members = SetStore.smembers(store, 0, "numbers")
      # Should be ordered numerically: 2, 10, 20, 100
      assert members == [2, 10, 20, 100]

      # Clean up
      SetStore.destroy(store)
    end
  end

  describe "set operations with different keys" do
    test "operations work correctly across different key names", %{store: store} do
      :ok = SetStore.sadd(store, 0, "fruits", ["apple", "banana", "cherry"])
      :ok = SetStore.sadd(store, 0, "colors", ["red", "yellow", "blue"])

      # Union
      :ok = SetStore.sunionstore(store, 0, "combined", ["fruits", "colors"])
      assert SetStore.scard(store, 0, "combined") == 6

      # Original sets remain unchanged
      assert SetStore.scard(store, 0, "fruits") == 3
      assert SetStore.scard(store, 0, "colors") == 3
    end
  end

  describe "large set operations" do
    test "handles large sets efficiently", %{store: store} do
      # Create large sets
      large_set1 = for i <- 1..1000, do: "element_#{i}"
      large_set2 = for i <- 500..1500, do: "element_#{i}"

      :ok = SetStore.sadd(store, 0, "large1", large_set1)
      :ok = SetStore.sadd(store, 0, "large2", large_set2)

      assert SetStore.scard(store, 0, "large1") == 1000
      assert SetStore.scard(store, 0, "large2") == 1001

      # Union
      :ok = SetStore.sunionstore(store, 0, "union", ["large1", "large2"])
      assert SetStore.scard(store, 0, "union") == 1500

      # Intersection
      :ok = SetStore.sinterstore(store, 0, "inter", ["large1", "large2"])
      # elements 500-1000
      assert SetStore.scard(store, 0, "inter") == 501

      # Difference
      :ok = SetStore.sdiffstore(store, 0, "diff", ["large1", "large2"])
      # elements 1-499
      assert SetStore.scard(store, 0, "diff") == 499
    end
  end
end
