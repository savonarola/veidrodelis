defmodule Vdr.SetStoreTest do
  use ExUnit.Case, async: true

  alias Vdr.ETSProj.Write.{Sets, Common}
  alias Vdr.ETSProj.Read

  setup do
    # Simple decode function that returns the element as-is
    decode_fun = fn _key, element -> element end

    # Create shared ETS table
    tid = :ets.new(:test_store, [:set, :public])

    write_store = Sets.new(tid, decode_fun)
    read_store = Read.Sets.new(tid)

    on_exit(fn ->
      try do
        :ets.delete(tid)
      rescue
        ArgumentError -> :ok
      end
    end)

    {:ok, write_store: write_store, read_store: read_store, tid: tid}
  end

  describe "new/2" do
    test "creates a SetStore with the given ETS table" do
      decode_fun = fn _key, element -> element end
      tid = :ets.new(:test_store, [:set, :public])
      write_store = Sets.new(tid, decode_fun)

      assert %Vdr.ETSProj.Write.Sets{tid: ^tid, decode_fun: ^decode_fun} = write_store
      assert is_reference(tid)
      assert :ets.info(tid) != :undefined

      # Clean up
      :ets.delete(tid)
    end
  end

  describe "sadd/4" do
    test "adds members to a set", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a", "b", "c"])

      members = Read.Sets.smembers(read_store, 0, "myset")
      assert Enum.sort(members) == ["a", "b", "c"]
    end

    test "adding duplicate members is idempotent", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a", "b"])
      :ok = Sets.sadd(write_store, 0, "myset", ["b", "c"])

      members = Read.Sets.smembers(read_store, 0, "myset")
      assert Enum.sort(members) == ["a", "b", "c"]
    end

    test "supports multiple databases", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a", "b"])
      :ok = Sets.sadd(write_store, 1, "myset", ["x", "y"])

      members_db0 = Read.Sets.smembers(read_store, 0, "myset")
      members_db1 = Read.Sets.smembers(read_store, 1, "myset")

      assert Enum.sort(members_db0) == ["a", "b"]
      assert Enum.sort(members_db1) == ["x", "y"]
    end

    test "adds empty list of members", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", [])

      members = Read.Sets.smembers(read_store, 0, "myset")
      assert members == []
    end
  end

  describe "srem/4" do
    test "removes members from a set", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a", "b", "c", "d"])
      :ok = Sets.srem(write_store, 0, "myset", ["b", "d"])

      members = Read.Sets.smembers(read_store, 0, "myset")
      assert Enum.sort(members) == ["a", "c"]
    end

    test "removing non-existent members is safe", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a", "b"])
      :ok = Sets.srem(write_store, 0, "myset", ["c", "d"])

      members = Read.Sets.smembers(read_store, 0, "myset")
      assert Enum.sort(members) == ["a", "b"]
    end

    test "removes all members", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a", "b", "c"])
      :ok = Sets.srem(write_store, 0, "myset", ["a", "b", "c"])

      members = Read.Sets.smembers(read_store, 0, "myset")
      assert members == []
    end
  end

  describe "smove/5" do
    test "moves member from source to destination", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b", "c"])
      :ok = Sets.sadd(write_store, 0, "set2", ["x", "y"])

      assert :ok = Sets.smove(write_store, 0, "set1", "set2", "b")

      members_set1 = Read.Sets.smembers(read_store, 0, "set1")
      members_set2 = Read.Sets.smembers(read_store, 0, "set2")

      assert Enum.sort(members_set1) == ["a", "c"]
      assert Enum.sort(members_set2) == ["b", "x", "y"]
    end

    test "returns :not_found if member doesn't exist in source", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b"])
      :ok = Sets.sadd(write_store, 0, "set2", ["x", "y"])

      assert :not_found = Sets.smove(write_store, 0, "set1", "set2", "z")

      members_set1 = Read.Sets.smembers(read_store, 0, "set1")
      members_set2 = Read.Sets.smembers(read_store, 0, "set2")

      assert Enum.sort(members_set1) == ["a", "b"]
      assert Enum.sort(members_set2) == ["x", "y"]
    end

    test "moves to non-existent destination set", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b"])

      assert :ok = Sets.smove(write_store, 0, "set1", "set2", "a")

      members_set1 = Read.Sets.smembers(read_store, 0, "set1")
      members_set2 = Read.Sets.smembers(read_store, 0, "set2")

      assert members_set1 == ["b"]
      assert members_set2 == ["a"]
    end

    test "handles moving from non-existent source", %{write_store: write_store} do
      assert :not_found = Sets.smove(write_store, 0, "nonexistent", "set2", "a")
    end
  end

  describe "sunionstore/4" do
    test "stores union of multiple sets", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b", "c"])
      :ok = Sets.sadd(write_store, 0, "set2", ["c", "d", "e"])
      :ok = Sets.sadd(write_store, 0, "set3", ["e", "f"])

      :ok = Sets.sunionstore(write_store, 0, "result", ["set1", "set2", "set3"])

      members = Read.Sets.smembers(read_store, 0, "result")
      assert Enum.sort(members) == ["a", "b", "c", "d", "e", "f"]
    end

    test "overwrites destination set", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b"])
      :ok = Sets.sadd(write_store, 0, "set2", ["c", "d"])
      :ok = Sets.sadd(write_store, 0, "result", ["x", "y", "z"])

      :ok = Sets.sunionstore(write_store, 0, "result", ["set1", "set2"])

      members = Read.Sets.smembers(read_store, 0, "result")
      assert Enum.sort(members) == ["a", "b", "c", "d"]
    end

    test "handles non-existent source sets", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b"])

      :ok = Sets.sunionstore(write_store, 0, "result", ["set1", "nonexistent"])

      members = Read.Sets.smembers(read_store, 0, "result")
      assert Enum.sort(members) == ["a", "b"]
    end

    test "handles empty source list", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "result", ["x", "y"])

      :ok = Sets.sunionstore(write_store, 0, "result", [])

      members = Read.Sets.smembers(read_store, 0, "result")
      assert members == []
    end

    test "can use destination as source", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b"])
      :ok = Sets.sadd(write_store, 0, "set2", ["c", "d"])

      :ok = Sets.sunionstore(write_store, 0, "set1", ["set1", "set2"])

      members = Read.Sets.smembers(read_store, 0, "set1")
      assert Enum.sort(members) == ["a", "b", "c", "d"]
    end
  end

  describe "sinterstore/4" do
    test "stores intersection of multiple sets", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b", "c", "d"])
      :ok = Sets.sadd(write_store, 0, "set2", ["c", "d", "e", "f"])
      :ok = Sets.sadd(write_store, 0, "set3", ["c", "d", "g"])

      :ok = Sets.sinterstore(write_store, 0, "result", ["set1", "set2", "set3"])

      members = Read.Sets.smembers(read_store, 0, "result")
      assert Enum.sort(members) == ["c", "d"]
    end

    test "empty result when no common elements", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b"])
      :ok = Sets.sadd(write_store, 0, "set2", ["c", "d"])

      :ok = Sets.sinterstore(write_store, 0, "result", ["set1", "set2"])

      members = Read.Sets.smembers(read_store, 0, "result")
      assert members == []
    end

    test "empty result when any source is non-existent", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b", "c"])

      :ok = Sets.sinterstore(write_store, 0, "result", ["set1", "nonexistent"])

      members = Read.Sets.smembers(read_store, 0, "result")
      assert members == []
    end

    test "overwrites destination set", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b", "c"])
      :ok = Sets.sadd(write_store, 0, "set2", ["b", "c", "d"])
      :ok = Sets.sadd(write_store, 0, "result", ["x", "y", "z"])

      :ok = Sets.sinterstore(write_store, 0, "result", ["set1", "set2"])

      members = Read.Sets.smembers(read_store, 0, "result")
      assert Enum.sort(members) == ["b", "c"]
    end

    test "handles empty source list", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sinterstore(write_store, 0, "result", [])

      members = Read.Sets.smembers(read_store, 0, "result")
      assert members == []
    end

    test "single set intersection returns that set", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b", "c"])

      :ok = Sets.sinterstore(write_store, 0, "result", ["set1"])

      members = Read.Sets.smembers(read_store, 0, "result")
      assert Enum.sort(members) == ["a", "b", "c"]
    end
  end

  describe "sdiffstore/4" do
    test "stores difference of multiple sets", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b", "c", "d"])
      :ok = Sets.sadd(write_store, 0, "set2", ["c"])
      :ok = Sets.sadd(write_store, 0, "set3", ["a", "d"])

      :ok = Sets.sdiffstore(write_store, 0, "result", ["set1", "set2", "set3"])

      members = Read.Sets.smembers(read_store, 0, "result")
      assert Enum.sort(members) == ["b"]
    end

    test "returns first set when subsequent sets are empty", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b", "c"])

      :ok = Sets.sdiffstore(write_store, 0, "result", ["set1", "nonexistent"])

      members = Read.Sets.smembers(read_store, 0, "result")
      assert Enum.sort(members) == ["a", "b", "c"]
    end

    test "empty result when first set is subset of others", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b"])
      :ok = Sets.sadd(write_store, 0, "set2", ["a", "b", "c", "d"])

      :ok = Sets.sdiffstore(write_store, 0, "result", ["set1", "set2"])

      members = Read.Sets.smembers(read_store, 0, "result")
      assert members == []
    end

    test "overwrites destination set", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b", "c"])
      :ok = Sets.sadd(write_store, 0, "set2", ["c", "d"])
      :ok = Sets.sadd(write_store, 0, "result", ["x", "y", "z"])

      :ok = Sets.sdiffstore(write_store, 0, "result", ["set1", "set2"])

      members = Read.Sets.smembers(read_store, 0, "result")
      assert Enum.sort(members) == ["a", "b"]
    end

    test "handles empty source list", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sdiffstore(write_store, 0, "result", [])

      members = Read.Sets.smembers(read_store, 0, "result")
      assert members == []
    end

    test "single set diff returns that set", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b", "c"])

      :ok = Sets.sdiffstore(write_store, 0, "result", ["set1"])

      members = Read.Sets.smembers(read_store, 0, "result")
      assert Enum.sort(members) == ["a", "b", "c"]
    end
  end

  describe "smembers/3" do
    test "returns all members of a set", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["apple", "banana", "cherry"])

      members = Read.Sets.smembers(read_store, 0, "myset")
      assert Enum.sort(members) == ["apple", "banana", "cherry"]
    end

    test "returns empty list for non-existent set", %{read_store: read_store} do
      members = Read.Sets.smembers(read_store, 0, "nonexistent")
      assert members == []
    end

    test "returns empty list for empty set", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a"])
      :ok = Sets.srem(write_store, 0, "myset", ["a"])

      members = Read.Sets.smembers(read_store, 0, "myset")
      assert members == []
    end
  end

  describe "sismember/4" do
    test "returns true when member exists", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a", "b", "c"])

      assert Read.Sets.sismember(read_store, 0, "myset", "b") == true
    end

    test "returns false when member doesn't exist", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a", "b", "c"])

      assert Read.Sets.sismember(read_store, 0, "myset", "d") == false
    end

    test "returns false for non-existent set", %{read_store: read_store} do
      assert Read.Sets.sismember(read_store, 0, "nonexistent", "a") == false
    end
  end

  describe "scard/3" do
    test "returns the number of members in a set", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a", "b", "c", "d", "e"])

      assert Read.Sets.scard(read_store, 0, "myset") == 5
    end

    test "returns 0 for non-existent set", %{read_store: read_store} do
      assert Read.Sets.scard(read_store, 0, "nonexistent") == 0
    end

    test "returns 0 for empty set", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a"])
      :ok = Sets.srem(write_store, 0, "myset", ["a"])

      assert Read.Sets.scard(read_store, 0, "myset") == 0
    end

    test "counts correctly with duplicates", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a", "b", "c"])
      # duplicates
      :ok = Sets.sadd(write_store, 0, "myset", ["a", "b", "c"])

      assert Read.Sets.scard(read_store, 0, "myset") == 3
    end
  end

  describe "del/3" do
    test "deletes an entire set", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a", "b", "c"])
      assert Read.Sets.scard(read_store, 0, "myset") == 3

      :ok = Common.del(write_store.tid, 0, "myset")

      assert Read.Sets.scard(read_store, 0, "myset") == 0
      assert Read.Sets.smembers(read_store, 0, "myset") == []
    end

    test "handles deleting non-existent set", %{write_store: write_store} do
      :ok = Common.del(write_store.tid, 0, "nonexistent")
    end

    test "only deletes specified database and key", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a", "b"])
      :ok = Sets.sadd(write_store, 1, "myset", ["x", "y"])
      :ok = Sets.sadd(write_store, 0, "other", ["z"])

      :ok = Common.del(write_store.tid, 0, "myset")

      assert Read.Sets.scard(read_store, 0, "myset") == 0
      assert Read.Sets.scard(read_store, 1, "myset") == 2
      assert Read.Sets.scard(read_store, 0, "other") == 1
    end
  end

  describe "decode function" do
    test "uses custom decode function for ordering" do
      # Decode function that converts to uppercase for case-insensitive ordering
      decode_fun = fn _key, element -> String.upcase(element) end

      tid = :ets.new(:test_store, [:set, :public])
      write_store = Sets.new(tid, decode_fun)
    read_store = Read.Sets.new(tid)

      :ok = Sets.sadd(write_store, 0, "myset", ["apple", "BANANA", "Cherry"])

      members = Read.Sets.smembers(read_store, 0, "myset")
      # Members are stored by their decoded (uppercased) keys
      assert Enum.sort(members) == ["APPLE", "BANANA", "CHERRY"]

      # Adding "APPLE" again should be idempotent (same decoded value)
      :ok = Sets.sadd(write_store, 0, "myset", ["APPLE"])
      assert Read.Sets.scard(read_store, 0, "myset") == 3

      # Clean up
      :ets.delete(tid)
    end

    test "decode function receives key for context" do
      # Decode function that includes key prefix
      decode_fun = fn key, element -> {key, element} end

      tid = :ets.new(:test_store, [:set, :public])
      write_store = Sets.new(tid, decode_fun)
    read_store = Read.Sets.new(tid)

      :ok = Sets.sadd(write_store, 0, "set1", ["a", "b"])
      :ok = Sets.sadd(write_store, 0, "set2", ["a", "b"])

      members_set1 = Read.Sets.smembers(read_store, 0, "set1")
      members_set2 = Read.Sets.smembers(read_store, 0, "set2")

      # Decoded values include the key, so they're different
      assert Enum.sort(members_set1) == [{"set1", "a"}, {"set1", "b"}]
      assert Enum.sort(members_set2) == [{"set2", "a"}, {"set2", "b"}]

      # Clean up
      :ets.delete(tid)
    end

    test "numeric decode function for integer-like strings" do
      # Decode function that converts strings to integers for numeric ordering
      decode_fun = fn _key, element ->
        case Integer.parse(element) do
          {num, ""} -> num
          _ -> element
        end
      end

      tid = :ets.new(:test_store, [:set, :public])
      write_store = Sets.new(tid, decode_fun)
    read_store = Read.Sets.new(tid)

      :ok = Sets.sadd(write_store, 0, "numbers", ["10", "2", "100", "20"])

      members = Read.Sets.smembers(read_store, 0, "numbers")
      # With :set table type, order is not guaranteed, so we check contents
      assert Enum.sort(members) == [2, 10, 20, 100]

      # Clean up
      :ets.delete(tid)
    end
  end

  describe "set operations with different keys" do
    test "operations work correctly across different key names", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "fruits", ["apple", "banana", "cherry"])
      :ok = Sets.sadd(write_store, 0, "colors", ["red", "yellow", "blue"])

      # Union
      :ok = Sets.sunionstore(write_store, 0, "combined", ["fruits", "colors"])
      assert Read.Sets.scard(read_store, 0, "combined") == 6

      # Original sets remain unchanged
      assert Read.Sets.scard(read_store, 0, "fruits") == 3
      assert Read.Sets.scard(read_store, 0, "colors") == 3
    end
  end

  describe "large set operations" do
    test "handles large sets efficiently", %{write_store: write_store, read_store: read_store} do
      # Create large sets
      large_set1 = for i <- 1..1000, do: "element_#{i}"
      large_set2 = for i <- 500..1500, do: "element_#{i}"

      :ok = Sets.sadd(write_store, 0, "large1", large_set1)
      :ok = Sets.sadd(write_store, 0, "large2", large_set2)

      assert Read.Sets.scard(read_store, 0, "large1") == 1000
      assert Read.Sets.scard(read_store, 0, "large2") == 1001

      # Union
      :ok = Sets.sunionstore(write_store, 0, "union", ["large1", "large2"])
      assert Read.Sets.scard(read_store, 0, "union") == 1500

      # Intersection
      :ok = Sets.sinterstore(write_store, 0, "inter", ["large1", "large2"])
      # elements 500-1000
      assert Read.Sets.scard(read_store, 0, "inter") == 501

      # Difference
      :ok = Sets.sdiffstore(write_store, 0, "diff", ["large1", "large2"])
      # elements 1-499
      assert Read.Sets.scard(read_store, 0, "diff") == 499
    end
  end

  describe "select_stream/4" do
    test "streams members matching a simple equality pattern", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["apple", "banana", "cherry", "avocado"])

      # Match pattern that matches members equal to "banana"
      match_pattern = {:"$1", [{:==, :"$1", "banana"}]}

      result =
        read_store
        |> Read.Sets.select_stream(0, "myset", match_pattern)
        |> Enum.to_list()

      assert ["banana"] = result
    end

    test "streams multiple matching members", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a", "b", "a1", "a2", "c"])

      # Match pattern that matches members "a1" or "a2"
      match_pattern = {:"$1", [{:orelse, {:==, :"$1", "a1"}, {:==, :"$1", "a2"}}]}

      result =
        read_store
        |> Read.Sets.select_stream(0, "myset", match_pattern)
        |> Enum.sort()

      assert ["a1", "a2"] = result
    end

    test "streams members with numeric pattern", %{} do
      # Use numeric decode function
      decode_fun = fn _key, element ->
        case Integer.parse(element) do
          {num, ""} -> num
          _ -> element
        end
      end

      tid = :ets.new(:test_store, [:set, :public])
      write_store = Sets.new(tid, decode_fun)
      read_store = Read.Sets.new(tid)

      :ok = Sets.sadd(write_store, 0, "numbers", ["1", "5", "10", "15", "20"])

      # Match pattern that matches members > 10
      match_pattern = {:"$1", [{:>, :"$1", 10}]}

      result =
        read_store
        |> Read.Sets.select_stream(0, "numbers", match_pattern)
        |> Enum.sort()

      assert [15, 20] = result

      :ets.delete(tid)
    end

    test "returns empty stream when no matches", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a", "b", "c"])

      # Match pattern that matches members equal to "x"
      match_pattern = {:"$1", [{:==, :"$1", "x"}]}

      result =
        read_store
        |> Read.Sets.select_stream(0, "myset", match_pattern)
        |> Enum.to_list()

      assert [] = result
    end

    test "returns empty stream for non-existent set", %{read_store: read_store} do
      match_pattern = {:"$1", [{:==, :"$1", "a"}]}

      result =
        read_store
        |> Read.Sets.select_stream(0, "nonexistent", match_pattern)
        |> Enum.to_list()

      assert [] = result
    end

    test "works with match all pattern", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a", "b", "c"])

      # Match pattern that matches all members using $1
      match_pattern = {:"$1", []}

      result =
        read_store
        |> Read.Sets.select_stream(0, "myset", match_pattern)
        |> Enum.sort()

      assert ["a", "b", "c"] = result
    end

    test "streams lazily", %{write_store: write_store, read_store: read_store} do
      members = for i <- 1..100, do: "elem_#{String.pad_leading("#{i}", 3, "0")}"
      :ok = Sets.sadd(write_store, 0, "myset", members)

      # Match all using $1 and take only first 5
      match_pattern = {:"$1", []}

      result =
        read_store
        |> Read.Sets.select_stream(0, "myset", match_pattern)
        |> Stream.take(5)
        |> Enum.to_list()

      assert length(result) == 5
    end
  end

  describe "select_rev_stream/4" do
    test "streams matching members in reverse order" do
      # Use ordered_set for predictable ordering
      tid = :ets.new(:test_store, [:ordered_set, :public])
      decode_fun = fn _key, element -> element end
      write_store = Sets.new(tid, decode_fun)
      read_store = Read.Sets.new(tid)

      :ok = Sets.sadd(write_store, 0, "myset", ["apple", "banana", "cherry"])

      # Match pattern that matches all members
      match_pattern = {:"$1", []}

      result =
        read_store
        |> Read.Sets.select_rev_stream(0, "myset", match_pattern)
        |> Enum.to_list()

      forward_result =
        read_store
        |> Read.Sets.select_stream(0, "myset", match_pattern)
        |> Enum.to_list()

      # Reverse stream should be reverse of forward stream with ordered_set
      assert result == Enum.reverse(forward_result)

      :ets.delete(tid)
    end

    test "streams numeric members in reverse order", %{} do
      # Use numeric decode function and ordered_set for predictable ordering
      decode_fun = fn _key, element ->
        case Integer.parse(element) do
          {num, ""} -> num
          _ -> element
        end
      end

      tid = :ets.new(:test_store, [:ordered_set, :public])
      write_store = Sets.new(tid, decode_fun)
      read_store = Read.Sets.new(tid)

      :ok = Sets.sadd(write_store, 0, "numbers", ["1", "5", "10", "15", "20"])

      # Match pattern that matches members > 5
      match_pattern = {:"$1", [{:>, :"$1", 5}]}

      result =
        read_store
        |> Read.Sets.select_rev_stream(0, "numbers", match_pattern)
        |> Enum.to_list()

      # Should be in descending order with ordered_set
      assert [20, 15, 10] = result

      :ets.delete(tid)
    end

    test "returns empty stream when no matches", %{write_store: write_store, read_store: read_store} do
      :ok = Sets.sadd(write_store, 0, "myset", ["a", "b", "c"])

      # Match pattern that matches members equal to "x"
      match_pattern = {:"$1", [{:==, :"$1", "x"}]}

      result =
        read_store
        |> Read.Sets.select_rev_stream(0, "myset", match_pattern)
        |> Enum.to_list()

      assert [] = result
    end

    test "returns empty stream for non-existent set", %{read_store: read_store} do
      match_pattern = {:"$1", [{:==, :"$1", "a"}]}

      result =
        read_store
        |> Read.Sets.select_rev_stream(0, "nonexistent", match_pattern)
        |> Enum.to_list()

      assert [] = result
    end

    test "streams lazily in reverse", %{write_store: write_store, read_store: read_store} do
      members = for i <- 1..100, do: "elem_#{String.pad_leading("#{i}", 3, "0")}"
      :ok = Sets.sadd(write_store, 0, "myset", members)

      # Match all and take only first 5 in reverse order
      match_pattern = {:"$1", []}

      result =
        read_store
        |> Read.Sets.select_rev_stream(0, "myset", match_pattern)
        |> Stream.take(5)
        |> Enum.to_list()

      assert length(result) == 5
    end
  end
end
