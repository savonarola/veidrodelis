defmodule Vdr.TSTest do
  use ExUnit.Case, async: true

  alias Vdr.TS

  describe "create/0" do
    test "creates a storage instance" do
      storage = TS.create()
      assert is_reference(storage)
    end

    test "creates independent instances" do
      storage1 = TS.create()
      storage2 = TS.create()

      TS.tx(storage1, [{0, {:set, "key", "value1"}}])
      TS.tx(storage2, [{0, {:set, "key", "value2"}}])

      assert "value1" == TS.get(storage1, 0, "key")
      assert "value2" == TS.get(storage2, 0, "key")
    end
  end

  describe "set/4 and get/3" do
    test "stores and retrieves binary values" do
      storage = TS.create()
      [:ok] = TS.tx(storage, [{0, {:set, "key", "value"}}])
      assert "value" == TS.get(storage, 0, "key")
    end

    test "stores and retrieves binary data" do
      storage = TS.create()
      data = <<0, 1, 2, 3, 4, 5>>
      [:ok] = TS.tx(storage, [{0, {:set, "data", data}}])
      assert ^data = TS.get(storage, 0, "data")
    end

    test "overwrites existing values" do
      storage = TS.create()

      TS.tx(storage, [{0, {:set, "key", "value1"}}])
      assert "value1" == TS.get(storage, 0, "key")

      TS.tx(storage, [{0, {:set, "key", "value2"}}])
      assert "value2" == TS.get(storage, 0, "key")
    end

    test "returns nil for missing keys" do
      storage = TS.create()
      assert nil == TS.get(storage, 0, "missing")
    end

    test "handles binary keys with colons" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "key:with:colons", "value"}}])
      assert "value" == TS.get(storage, 0, "key:with:colons")
    end

    test "handles binary keys with slashes" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "key/with/slashes", "value"}}])
      assert "value" == TS.get(storage, 0, "key/with/slashes")
    end

    test "handles binary keys with spaces" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "key with spaces", "value"}}])
      assert "value" == TS.get(storage, 0, "key with spaces")
    end

    test "handles empty binary key" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "", "empty_key"}}])
      assert "empty_key" == TS.get(storage, 0, "")
    end

    test "handles empty binary value" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "key", ""}}])
      assert "" == TS.get(storage, 0, "key")
    end

    test "handles UTF-8 binary values" do
      storage = TS.create()
      utf8_value = "Hello, 世界! 🌍"
      TS.tx(storage, [{0, {:set, "utf8", utf8_value}}])
      assert ^utf8_value = TS.get(storage, 0, "utf8")
    end
  end

  describe "del/3" do
    test "deletes existing keys" do
      storage = TS.create()

      TS.tx(storage, [{0, {:set, "key", "value"}}])
      assert "value" == TS.get(storage, 0, "key")

      [:ok] = TS.tx(storage, [{0, {:del, ["key"]}}])
      assert nil == TS.get(storage, 0, "key")
    end

    test "returns :ok for missing keys" do
      storage = TS.create()
      assert [:ok] == TS.tx(storage, [{0, {:del, ["missing"]}}])
    end

    test "allows re-setting after deletion" do
      storage = TS.create()

      TS.tx(storage, [{0, {:set, "key", "value1"}}])
      TS.tx(storage, [{0, {:del, ["key"]}}])
      TS.tx(storage, [{0, {:set, "key", "value2"}}])

      assert "value2" == TS.get(storage, 0, "key")
    end

    test "deleting multiple times is idempotent" do
      storage = TS.create()

      TS.tx(storage, [{0, {:set, "key", "value"}}])
      assert [:ok] = TS.tx(storage, [{0, {:del, ["key"]}}])
      assert [:ok] = TS.tx(storage, [{0, {:del, ["key"]}}])
      assert [:ok] = TS.tx(storage, [{0, {:del, ["key"]}}])
    end
  end

  describe "destroy/1" do
    test "clears all data" do
      storage = TS.create()

      TS.tx(storage, [{0, {:set, "key1", "value1"}}])
      TS.tx(storage, [{0, {:set, "key2", "value2"}}])
      TS.tx(storage, [{0, {:set, "key3", "value3"}}])

      :ok = TS.destroy(storage)

      assert nil == TS.get(storage, 0, "key1")
      assert nil == TS.get(storage, 0, "key2")
      assert nil == TS.get(storage, 0, "key3")
    end

    test "storage can be reused after destroy" do
      storage = TS.create()

      TS.tx(storage, [{0, {:set, "key1", "value1"}}])
      TS.destroy(storage)

      TS.tx(storage, [{0, {:set, "key2", "value2"}}])
      assert "value2" == TS.get(storage, 0, "key2")
      assert nil == TS.get(storage, 0, "key1")
    end
  end

  describe "concurrent access" do
    test "handles concurrent reads and writes" do
      storage = TS.create()

      # Pre-populate
      for i <- 1..10 do
        TS.tx(storage, [{0, {:set, "key#{i}", "value#{i}"}}])
      end

      # Concurrent access from multiple tasks
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            # Each task reads and writes
            TS.tx(storage, [{0, {:set, "task#{i}", "task_value_#{i}"}}])
            TS.get(storage, 0, "key#{i}")
          end)
        end

      results = Task.await_many(tasks)
      assert ["value1", "value2", "value3", "value4", "value5"] == results

      # Verify task writes succeeded
      for i <- 1..5 do
        assert "task_value_#{i}" == TS.get(storage, 0, "task#{i}")
      end
    end

    test "handles concurrent writes to same key" do
      storage = TS.create()

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            TS.tx(storage, [{0, {:set, "shared", "value#{i}"}}])
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == [:ok]))

      # Some value should be stored (we don't know which due to race)
      value = TS.get(storage, 0, "shared")
      assert is_binary(value)
      assert String.starts_with?(value, "value")
    end

    test "handles concurrent deletes" do
      storage = TS.create()

      # Pre-populate
      for i <- 1..10 do
        TS.tx(storage, [{0, {:set, "key#{i}", "value#{i}"}}])
      end

      # Concurrent deletes
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            TS.tx(storage, [{0, {:del, ["key#{i}"]}}])
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == [:ok]))

      # All keys should be deleted
      for i <- 1..10 do
        assert nil == TS.get(storage, 0, "key#{i}")
      end
    end
  end

  describe "binary preservation" do
    test "preserves binary data exactly" do
      storage = TS.create()

      binary = <<0, 1, 2, 255, 254, 253>>
      TS.tx(storage, [{0, {:set, "binary", binary}}])

      assert ^binary = TS.get(storage, 0, "binary")
    end

    test "handles large binary values" do
      storage = TS.create()

      # 1MB binary
      large_binary = :crypto.strong_rand_bytes(1024 * 1024)
      TS.tx(storage, [{0, {:set, "large", large_binary}}])

      assert ^large_binary = TS.get(storage, 0, "large")
    end

    test "different binary values for same key across time" do
      storage = TS.create()

      TS.tx(storage, [{0, {:set, "key", "value1"}}])
      assert "value1" == TS.get(storage, 0, "key")

      TS.tx(storage, [{0, {:set, "key", "value2"}}])
      assert "value2" == TS.get(storage, 0, "key")

      TS.tx(storage, [{0, {:set, "key", <<1, 2, 3>>}}])
      assert <<1, 2, 3>> == TS.get(storage, 0, "key")
    end
  end

  describe "edge cases" do
    test "handles many keys" do
      storage = TS.create()

      # Store 100 keys
      for i <- 1..100 do
        TS.tx(storage, [{0, {:set, "key#{i}", "value#{i}"}}])
      end

      # Verify all keys
      for i <- 1..100 do
        assert "value#{i}" == TS.get(storage, 0, "key#{i}")
      end
    end

    test "handles keys and values with null bytes" do
      storage = TS.create()

      key = "key\0with\0nulls"
      value = "value\0with\0nulls"

      TS.tx(storage, [{0, {:set, key, value}}])
      assert ^value = TS.get(storage, 0, key)
    end
  end

  describe "zcount/5" do
    test "returns 0 for empty zset" do
      storage = TS.create()
      assert {:ok, 0} == TS.zcount(storage, 0, "nonexistent", 0.0, 10.0)
    end

    test "returns 0 for empty zset via Lua" do
      storage = TS.create()
      script = "return ts.zcount('nonexistent', 0.0, 10.0)"
      assert {:ok, 0} == TS.read_tx(storage, 0, script)
    end

    test "returns 0 when no elements in range" do
      storage = TS.create()
      [{:ok, 3}] = TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}]}}])

      # Range before all elements
      assert {:ok, 0} == TS.zcount(storage, 0, "myzset", -10.0, 0.5)

      # Range after all elements
      assert {:ok, 0} == TS.zcount(storage, 0, "myzset", 5.0, 10.0)

      # Range between elements
      assert {:ok, 0} == TS.zcount(storage, 0, "myzset", 1.5, 1.9)
    end

    test "counts all elements when range covers all" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}, {4.0, "d"}, {5.0, "e"}]}}])

      # Range that covers all elements
      assert {:ok, 5} == TS.zcount(storage, 0, "myzset", 0.0, 10.0)
      assert {:ok, 5} == TS.zcount(storage, 0, "myzset", 1.0, 5.0)
    end

    test "min boundary is inclusive" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}, {4.0, "d"}, {5.0, "e"}]}}])

      # Min boundary exactly at element - should include it
      assert {:ok, 4} == TS.zcount(storage, 0, "myzset", 2.0, 10.0)
      assert {:ok, 5} == TS.zcount(storage, 0, "myzset", 1.0, 10.0)
      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", 5.0, 10.0)
    end

    test "max boundary is inclusive" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}, {4.0, "d"}, {5.0, "e"}]}}])

      # Max boundary exactly at element - should include it
      assert {:ok, 3} == TS.zcount(storage, 0, "myzset", 0.0, 3.0)
      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", 0.0, 1.0)
      assert {:ok, 5} == TS.zcount(storage, 0, "myzset", 0.0, 5.0)
    end

    test "both boundaries are inclusive" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}, {4.0, "d"}, {5.0, "e"}]}}])

      # Both boundaries exactly at elements - should include both
      assert {:ok, 3} == TS.zcount(storage, 0, "myzset", 2.0, 4.0)
      assert {:ok, 5} == TS.zcount(storage, 0, "myzset", 1.0, 5.0)
      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", 3.0, 3.0)
    end

    test "single element exact match" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{2.5, "x"}]}}])

      # Exact match for single element
      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", 2.5, 2.5)

      # Range that includes the element
      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", 2.0, 3.0)

      # Range that excludes the element
      assert {:ok, 0} == TS.zcount(storage, 0, "myzset", 3.0, 4.0)
      assert {:ok, 0} == TS.zcount(storage, 0, "myzset", 1.0, 2.0)
    end

    test "multiple elements with same score" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b1"}, {2.0, "b2"}, {2.0, "b3"}, {3.0, "c"}]}}])

      # Range that includes all elements with score 2.0
      assert {:ok, 3} == TS.zcount(storage, 0, "myzset", 2.0, 2.0)

      # Range that includes elements with score 2.0 and others
      assert {:ok, 3} == TS.zcount(storage, 0, "myzset", 1.5, 2.5)
      assert {:ok, 4} == TS.zcount(storage, 0, "myzset", 2.0, 3.0)
      assert {:ok, 4} == TS.zcount(storage, 0, "myzset", 1.0, 2.0)
    end

    test "negative and positive scores" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{-5.0, "a"}, {-2.0, "b"}, {0.0, "c"}, {2.0, "d"}, {5.0, "e"}]}}])

      # Range spanning negative to positive
      assert {:ok, 3} == TS.zcount(storage, 0, "myzset", -3.0, 3.0)

      # Only negative scores
      assert {:ok, 2} == TS.zcount(storage, 0, "myzset", -10.0, -1.0)

      # Only positive scores
      assert {:ok, 2} == TS.zcount(storage, 0, "myzset", 1.0, 10.0)

      # Including zero
      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", -1.0, 1.0)
      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", 0.0, 0.0)
    end

    test "fractional boundaries" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}, {4.0, "d"}, {5.0, "e"}]}}])

      # Boundaries between integer scores
      assert {:ok, 2} == TS.zcount(storage, 0, "myzset", 1.5, 3.5)
      assert {:ok, 2} == TS.zcount(storage, 0, "myzset", 0.5, 2.5)
      assert {:ok, 2} == TS.zcount(storage, 0, "myzset", 2.1, 4.9)
    end

    test "inverted range returns 0" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}]}}])

      # Min > Max should return 0
      assert {:ok, 0} == TS.zcount(storage, 0, "myzset", 3.0, 1.0)
    end

    test "large dataset" do
      storage = TS.create()

      # Create 1000 members with scores from 0 to 999
      members = for i <- 0..999, do: {i * 1.0, "member#{i}"}
      TS.tx(storage, [{0, {:zadd, "large_zset", members}}])

      # Test various ranges
      assert {:ok, 1000} == TS.zcount(storage, 0, "large_zset", 0.0, 999.0)
      assert {:ok, 100} == TS.zcount(storage, 0, "large_zset", 100.0, 199.0)
      assert {:ok, 1} == TS.zcount(storage, 0, "large_zset", 500.0, 500.0)
      assert {:ok, 500} == TS.zcount(storage, 0, "large_zset", 250.0, 749.0)
    end

    test "returns error for wrong type" do
      storage = TS.create()
      [:ok] = TS.tx(storage, [{0, {:set, "mystring", "value"}}])

      assert {:error, :wrong_type} == TS.zcount(storage, 0, "mystring", 0.0, 10.0)
    end

    test "handles boundary precision with floats" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.1, "a"}, {1.5, "b"}, {1.9, "c"}, {2.0, "d"}]}}])

      # Test precise boundaries
      assert {:ok, 3} == TS.zcount(storage, 0, "myzset", 1.1, 1.9)
      assert {:ok, 3} == TS.zcount(storage, 0, "myzset", 1.5, 2.0)
      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", 1.9, 1.9)
    end

    test "empty range at exact score" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {3.0, "b"}]}}])

      # Range at a score where no element exists
      assert {:ok, 0} == TS.zcount(storage, 0, "myzset", 2.0, 2.0)
    end

    test "very large score values" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0e10, "a"}, {2.0e10, "b"}, {3.0e10, "c"}]}}])

      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", 1.5e10, 2.5e10)
      assert {:ok, 3} == TS.zcount(storage, 0, "myzset", 0.0, 1.0e11)
    end

    test "very small score differences" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{0.001, "a"}, {0.002, "b"}, {0.003, "c"}]}}])

      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", 0.0015, 0.0025)
      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", 0.001, 0.001)
    end

    test "counts elements in range via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}, {4.0, "d"}]}}])

      script = "return ts.zcount('myzset', 1.5, 3.5)"
      assert {:ok, 2} == TS.read_tx(storage, 0, script)
    end
  end

  describe "zfirst/3" do
    test "returns first member from sorted set" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{3.0, "three"}, {1.0, "one"}, {2.0, "two"}]}}])

      assert {:ok, {1.0, "one"}} == TS.zfirst(storage, 0, "myzset")
    end

    test "returns nil for empty set" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", []}}])

      assert {:ok, nil} == TS.zfirst(storage, 0, "myzset")
    end

    test "returns nil for nonexistent key" do
      storage = TS.create()

      assert {:ok, nil} == TS.zfirst(storage, 0, "nonexistent")
    end

    test "returns error for wrong type" do
      storage = TS.create()
      [:ok] = TS.tx(storage, [{0, {:set, "mystring", "value"}}])

      assert {:error, :wrong_type} == TS.zfirst(storage, 0, "mystring")
    end

    test "handles members with same score" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {1.0, "b"}, {1.0, "c"}]}}])

      # Should return lexicographically first member at the minimum score
      assert {:ok, {1.0, member}} = TS.zfirst(storage, 0, "myzset")
      assert member == "a"
    end

    test "returns first member via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}]}}])

      script = """
      local score, member = ts.zfirst('myzset')
      return member .. ':' .. score
      """
      assert {:ok, "a:1"} == TS.read_tx(storage, 0, script)
    end

    test "returns nil for empty set via Lua" do
      storage = TS.create()

      script = """
      local score, member = ts.zfirst('nonexistent')
      if score == nil then
        return 'nil'
      else
        return 'not nil'
      end
      """
      assert {:ok, "nil"} == TS.read_tx(storage, 0, script)
    end
  end

  describe "zlast/3" do
    test "returns last member from sorted set" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "one"}, {3.0, "three"}, {2.0, "two"}]}}])

      assert {:ok, {3.0, "three"}} == TS.zlast(storage, 0, "myzset")
    end

    test "returns nil for empty set" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", []}}])

      assert {:ok, nil} == TS.zlast(storage, 0, "myzset")
    end

    test "returns nil for nonexistent key" do
      storage = TS.create()

      assert {:ok, nil} == TS.zlast(storage, 0, "nonexistent")
    end

    test "returns error for wrong type" do
      storage = TS.create()
      [:ok] = TS.tx(storage, [{0, {:set, "mystring", "value"}}])

      assert {:error, :wrong_type} == TS.zlast(storage, 0, "mystring")
    end

    test "handles members with same score" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "x"}, {1.0, "y"}, {1.0, "z"}]}}])

      # Should return lexicographically last member at the maximum score
      assert {:ok, {1.0, member}} = TS.zlast(storage, 0, "myzset")
      assert member == "z"
    end

    test "returns last member via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}]}}])

      script = """
      local score, member = ts.zlast('myzset')
      return member .. ':' .. score
      """
      assert {:ok, "c:3"} == TS.read_tx(storage, 0, script)
    end
  end

  describe "znext/5" do
    test "returns next member after given position" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "one"}, {2.0, "two"}, {3.0, "three"}]}}])

      assert {:ok, {2.0, "two"}} == TS.znext(storage, 0, "myzset", 1.0, "one")
      assert {:ok, {3.0, "three"}} == TS.znext(storage, 0, "myzset", 2.0, "two")
    end

    test "returns nil when at the end" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "one"}, {2.0, "two"}, {3.0, "three"}]}}])

      assert {:ok, nil} == TS.znext(storage, 0, "myzset", 3.0, "three")
    end

    test "returns nil for nonexistent key" do
      storage = TS.create()

      assert {:ok, nil} == TS.znext(storage, 0, "nonexistent", 1.0, "member")
    end

    test "returns error for wrong type" do
      storage = TS.create()
      [:ok] = TS.tx(storage, [{0, {:set, "mystring", "value"}}])

      assert {:error, :wrong_type} == TS.znext(storage, 0, "mystring", 1.0, "member")
    end

    test "handles members with same score" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {1.0, "b"}, {1.0, "c"}, {2.0, "d"}]}}])

      # Should navigate through members lexicographically at same score
      assert {:ok, {1.0, "b"}} == TS.znext(storage, 0, "myzset", 1.0, "a")
      assert {:ok, {1.0, "c"}} == TS.znext(storage, 0, "myzset", 1.0, "b")
      assert {:ok, {2.0, "d"}} == TS.znext(storage, 0, "myzset", 1.0, "c")
    end

    test "navigates through entire set" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}, {4.0, "d"}]}}])

      assert {:ok, {2.0, "b"}} = TS.znext(storage, 0, "myzset", 1.0, "a")
      assert {:ok, {3.0, "c"}} = TS.znext(storage, 0, "myzset", 2.0, "b")
      assert {:ok, {4.0, "d"}} = TS.znext(storage, 0, "myzset", 3.0, "c")
      assert {:ok, nil} = TS.znext(storage, 0, "myzset", 4.0, "d")
    end

    test "returns next member via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}]}}])

      script = """
      local score, member = ts.znext('myzset', 1.0, 'a')
      return member .. ':' .. score
      """
      assert {:ok, "b:2"} == TS.read_tx(storage, 0, script)
    end

    test "returns nil at end via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}]}}])

      script = """
      local score, member = ts.znext('myzset', 2.0, 'b')
      if score == nil then
        return 'nil'
      else
        return 'not nil'
      end
      """
      assert {:ok, "nil"} == TS.read_tx(storage, 0, script)
    end
  end

  describe "zprev/5" do
    test "returns previous member before given position" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "one"}, {2.0, "two"}, {3.0, "three"}]}}])

      assert {:ok, {2.0, "two"}} == TS.zprev(storage, 0, "myzset", 3.0, "three")
      assert {:ok, {1.0, "one"}} == TS.zprev(storage, 0, "myzset", 2.0, "two")
    end

    test "returns nil when at the beginning" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "one"}, {2.0, "two"}, {3.0, "three"}]}}])

      assert {:ok, nil} == TS.zprev(storage, 0, "myzset", 1.0, "one")
    end

    test "returns nil for nonexistent key" do
      storage = TS.create()

      assert {:ok, nil} == TS.zprev(storage, 0, "nonexistent", 1.0, "member")
    end

    test "returns error for wrong type" do
      storage = TS.create()
      [:ok] = TS.tx(storage, [{0, {:set, "mystring", "value"}}])

      assert {:error, :wrong_type} == TS.zprev(storage, 0, "mystring", 1.0, "member")
    end

    test "handles members with same score" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {2.0, "c"}, {2.0, "d"}]}}])

      # Should navigate through members lexicographically at same score
      assert {:ok, {2.0, "c"}} == TS.zprev(storage, 0, "myzset", 2.0, "d")
      assert {:ok, {2.0, "b"}} == TS.zprev(storage, 0, "myzset", 2.0, "c")
      assert {:ok, {1.0, "a"}} == TS.zprev(storage, 0, "myzset", 2.0, "b")
    end

    test "navigates through entire set backwards" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}, {4.0, "d"}]}}])

      assert {:ok, {3.0, "c"}} = TS.zprev(storage, 0, "myzset", 4.0, "d")
      assert {:ok, {2.0, "b"}} = TS.zprev(storage, 0, "myzset", 3.0, "c")
      assert {:ok, {1.0, "a"}} = TS.zprev(storage, 0, "myzset", 2.0, "b")
      assert {:ok, nil} = TS.zprev(storage, 0, "myzset", 1.0, "a")
    end

    test "returns previous member via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}]}}])

      script = """
      local score, member = ts.zprev('myzset', 3.0, 'c')
      return member .. ':' .. score
      """
      assert {:ok, "b:2"} == TS.read_tx(storage, 0, script)
    end

    test "returns nil at beginning via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}]}}])

      script = """
      local score, member = ts.zprev('myzset', 1.0, 'a')
      if score == nil then
        return 'nil'
      else
        return 'not nil'
      end
      """
      assert {:ok, "nil"} == TS.read_tx(storage, 0, script)
    end
  end

  describe "zset navigation integration" do
    test "traverse entire set forward with znext" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}]}}])

      # Start from first
      {:ok, {score1, member1}} = TS.zfirst(storage, 0, "myzset")
      assert {score1, member1} == {1.0, "a"}

      # Navigate to next
      {:ok, {score2, member2}} = TS.znext(storage, 0, "myzset", score1, member1)
      assert {score2, member2} == {2.0, "b"}

      # Navigate to next again
      {:ok, {score3, member3}} = TS.znext(storage, 0, "myzset", score2, member2)
      assert {score3, member3} == {3.0, "c"}

      # No more elements
      {:ok, nil} = TS.znext(storage, 0, "myzset", score3, member3)
    end

    test "traverse entire set backward with zprev" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}]}}])

      # Start from last
      {:ok, {score3, member3}} = TS.zlast(storage, 0, "myzset")
      assert {score3, member3} == {3.0, "c"}

      # Navigate to previous
      {:ok, {score2, member2}} = TS.zprev(storage, 0, "myzset", score3, member3)
      assert {score2, member2} == {2.0, "b"}

      # Navigate to previous again
      {:ok, {score1, member1}} = TS.zprev(storage, 0, "myzset", score2, member2)
      assert {score1, member1} == {1.0, "a"}

      # No more elements
      {:ok, nil} = TS.zprev(storage, 0, "myzset", score1, member1)
    end

    test "traverse entire set forward with znext via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}]}}])

      script = """
      local result = {}
      local score, member = ts.zfirst('myzset')
      while score ~= nil do
        table.insert(result, member)
        score, member = ts.znext('myzset', score, member)
      end
      return table.concat(result, ',')
      """
      assert {:ok, "a,b,c"} == TS.read_tx(storage, 0, script)
    end

    test "traverse entire set backward with zprev via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:zadd, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}]}}])

      script = """
      local result = {}
      local score, member = ts.zlast('myzset')
      while score ~= nil do
        table.insert(result, member)
        score, member = ts.zprev('myzset', score, member)
      end
      return table.concat(result, ',')
      """
      assert {:ok, "c,b,a"} == TS.read_tx(storage, 0, script)
    end
  end

  describe "tx/3 - Lua transactions" do
    test "executes simple Lua script with ts.get" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "key1", "value1"}}])

      script = "return ts.get('key1')"
      assert {:ok, "value1"} == TS.read_tx(storage, 0, script)
    end

    test "executes Lua script with ts.hget" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hset, "hash1", "field1", "value1"}}])

      script = "return ts.hget('hash1', 'field1')"
      assert {:ok, "value1"} == TS.read_tx(storage, 0, script)
    end

    test "combines multiple ts.get calls" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "key1", "hello"}}])
      TS.tx(storage, [{0, {:set, "key2", "world"}}])

      script = """
      local v1 = ts.get('key1')
      local v2 = ts.get('key2')
      return v1 .. ' ' .. v2
      """

      assert {:ok, "hello world"} == TS.read_tx(storage, 0, script)
    end

    test "combines ts.get and ts.hget" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "string_key", "prefix"}}])
      TS.tx(storage, [{0, {:hset, "hash_key", "field1", "suffix"}}])

      script = """
      local v1 = ts.get('string_key')
      local v2 = ts.hget('hash_key', 'field1')
      return v1 .. ':' .. v2
      """

      assert {:ok, "prefix:suffix"} == TS.read_tx(storage, 0, script)
    end

    test "returns nil when key doesn't exist" do
      storage = TS.create()

      script = """
      local v = ts.get('nonexistent')
      if v == nil then
        return 'not found'
      else
        return v
      end
      """

      assert {:ok, "not found"} == TS.read_tx(storage, 0, script)
    end

    test "returns integer result" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "count", "5"}}])

      script = """
      local v = ts.get('count')
      return tonumber(v) * 2
      """

      assert {:ok, 10} == TS.read_tx(storage, 0, script)
    end

    test "returns boolean result" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "key1", "value1"}}])

      script = """
      local v = ts.get('key1')
      return v ~= nil
      """

      assert {:ok, true} == TS.read_tx(storage, 0, script)
    end

    test "executes atomically under mutex" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "counter", "0"}}])

      # Run multiple scripts concurrently
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            script = """
            local v = ts.get('counter')
            return v .. '-' .. '#{i}'
            """
            TS.read_tx(storage, 0, script)
          end)
        end

      results = Task.await_many(tasks)
      # All should succeed
      assert Enum.all?(results, fn
        {:ok, _} -> true
        _ -> false
      end)
    end

    test "handles empty script result" do
      storage = TS.create()

      script = "return nil"
      assert {:ok, nil} == TS.read_tx(storage, 0, script)
    end

    test "returns error for Lua syntax error" do
      storage = TS.create()

      script = "return ts.get('key'"  # Missing closing paren
      assert {:error, _} = TS.read_tx(storage, 0, script)
    end

    test "isolates by database" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "key", "db0"}}])
      TS.tx(storage, [{1, {:set, "key", "db1"}}])

      script = "return ts.get('key')"

      assert {:ok, "db0"} == TS.read_tx(storage, 0, script)
      assert {:ok, "db1"} == TS.read_tx(storage, 1, script)
    end

    test "handles binary data in values" do
      storage = TS.create()
      binary_value = <<0, 1, 2, 3, 255, 254, 253>>
      TS.tx(storage, [{0, {:set, "binary_key", binary_value}}])

      script = "return ts.get('binary_key')"
      assert {:ok, ^binary_value} = TS.read_tx(storage, 0, script)
    end

    test "returns Lua table as Elixir list" do
      storage = TS.create()

      script = "return {1, 2, 3, 4, 5}"
      assert {:ok, [1, 2, 3, 4, 5]} == TS.read_tx(storage, 0, script)
    end

    test "returns Lua table as Elixir map" do
      storage = TS.create()

      script = "return {a = 1, b = 2, c = 3}"
      assert {:ok, %{"a" => 1, "b" => 2, "c" => 3}} == TS.read_tx(storage, 0, script)
    end

    test "handles nested Lua tables" do
      storage = TS.create()

      script = "return {1, 2, {a = 10, b = 20}, 4}"
      assert {:ok, [1, 2, %{"a" => 10, "b" => 20}, 4]} == TS.read_tx(storage, 0, script)
    end

    test "handles mixed types in table" do
      storage = TS.create()

      # Note: Lua tables with nil in the middle terminate early
      script = "return {42, 'hello', true}"
      assert {:ok, [42, "hello", true]} == TS.read_tx(storage, 0, script)
    end

    test "returns number types correctly" do
      storage = TS.create()

      script = "return 42"
      assert {:ok, 42} == TS.read_tx(storage, 0, script)

      script = "return 3.14"
      assert {:ok, 3.14} == TS.read_tx(storage, 0, script)
    end

    test "returns boolean types correctly" do
      storage = TS.create()

      script = "return true"
      assert {:ok, true} == TS.read_tx(storage, 0, script)

      script = "return false"
      assert {:ok, false} == TS.read_tx(storage, 0, script)
    end
  end

  describe "lua_load/2" do
    test "compiles script to bytecode" do
      storage = TS.create()
      script = "return 42"

      assert {:ok, bytecode} = TS.lua_load(storage, script)
      assert is_binary(bytecode)
      assert byte_size(bytecode) > 0
    end

    test "returns error for invalid script" do
      storage = TS.create()
      script = "return ts.get('key'"  # Missing closing paren

      assert {:error, _} = TS.lua_load(storage, script)
    end

    test "bytecode can be executed with tx" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "key", "value"}}])

      script = "return ts.get('key')"
      {:ok, bytecode} = TS.lua_load(storage, script)

      # Execute bytecode
      assert {:ok, "value"} = TS.read_tx(storage, 0, bytecode)
    end

    test "bytecode can be reused across multiple tx calls" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "key0", "value0"}}])
      TS.tx(storage, [{1, {:set, "key1", "value1"}}])

      script = "return ts.get('key' .. __db)"
      {:ok, bytecode} = TS.lua_load(storage, script)

      # Use same bytecode with different databases
      assert {:ok, "value0"} = TS.read_tx(storage, 0, bytecode)
      assert {:ok, "value1"} = TS.read_tx(storage, 1, bytecode)
    end

    test "bytecode works with complex scripts" do
      storage = TS.create()
      TS.tx(storage, [{0, {:set, "a", "hello"}}])
      TS.tx(storage, [{0, {:set, "b", "world"}}])

      script = """
      local v1 = ts.get('a')
      local v2 = ts.get('b')
      return v1 .. ' ' .. v2
      """

      {:ok, bytecode} = TS.lua_load(storage, script)
      assert {:ok, "hello world"} = TS.read_tx(storage, 0, bytecode)
    end
  end
end
