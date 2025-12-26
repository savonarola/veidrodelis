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

      TS.set(storage1, 0, "key", "value1")
      TS.set(storage2, 0, "key", "value2")

      assert "value1" == TS.get(storage1, 0, "key")
      assert "value2" == TS.get(storage2, 0, "key")
    end
  end

  describe "set/4 and get/3" do
    test "stores and retrieves binary values" do
      storage = TS.create()
      :ok = TS.set(storage, 0, "key", "value")
      assert "value" == TS.get(storage, 0, "key")
    end

    test "stores and retrieves binary data" do
      storage = TS.create()
      data = <<0, 1, 2, 3, 4, 5>>
      :ok = TS.set(storage, 0, "data", data)
      assert ^data = TS.get(storage, 0, "data")
    end

    test "overwrites existing values" do
      storage = TS.create()

      TS.set(storage, 0, "key", "value1")
      assert "value1" == TS.get(storage, 0, "key")

      TS.set(storage, 0, "key", "value2")
      assert "value2" == TS.get(storage, 0, "key")
    end

    test "returns nil for missing keys" do
      storage = TS.create()
      assert nil == TS.get(storage, 0, "missing")
    end

    test "handles binary keys with colons" do
      storage = TS.create()
      TS.set(storage, 0, "key:with:colons", "value")
      assert "value" == TS.get(storage, 0, "key:with:colons")
    end

    test "handles binary keys with slashes" do
      storage = TS.create()
      TS.set(storage, 0, "key/with/slashes", "value")
      assert "value" == TS.get(storage, 0, "key/with/slashes")
    end

    test "handles binary keys with spaces" do
      storage = TS.create()
      TS.set(storage, 0, "key with spaces", "value")
      assert "value" == TS.get(storage, 0, "key with spaces")
    end

    test "handles empty binary key" do
      storage = TS.create()
      TS.set(storage, 0, "", "empty_key")
      assert "empty_key" == TS.get(storage, 0, "")
    end

    test "handles empty binary value" do
      storage = TS.create()
      TS.set(storage, 0, "key", "")
      assert "" == TS.get(storage, 0, "key")
    end

    test "handles UTF-8 binary values" do
      storage = TS.create()
      utf8_value = "Hello, 世界! 🌍"
      TS.set(storage, 0, "utf8", utf8_value)
      assert ^utf8_value = TS.get(storage, 0, "utf8")
    end
  end

  describe "del/3" do
    test "deletes existing keys" do
      storage = TS.create()

      TS.set(storage, 0, "key", "value")
      assert "value" == TS.get(storage, 0, "key")

      :ok = TS.del(storage, 0, "key")
      assert nil == TS.get(storage, 0, "key")
    end

    test "returns :ok for missing keys" do
      storage = TS.create()
      assert :ok == TS.del(storage, 0, "missing")
    end

    test "allows re-setting after deletion" do
      storage = TS.create()

      TS.set(storage, 0, "key", "value1")
      TS.del(storage, 0, "key")
      TS.set(storage, 0, "key", "value2")

      assert "value2" == TS.get(storage, 0, "key")
    end

    test "deleting multiple times is idempotent" do
      storage = TS.create()

      TS.set(storage, 0, "key", "value")
      assert :ok = TS.del(storage, 0, "key")
      assert :ok = TS.del(storage, 0, "key")
      assert :ok = TS.del(storage, 0, "key")
    end
  end

  describe "destroy/1" do
    test "clears all data" do
      storage = TS.create()

      TS.set(storage, 0, "key1", "value1")
      TS.set(storage, 0, "key2", "value2")
      TS.set(storage, 0, "key3", "value3")

      :ok = TS.destroy(storage)

      assert nil == TS.get(storage, 0, "key1")
      assert nil == TS.get(storage, 0, "key2")
      assert nil == TS.get(storage, 0, "key3")
    end

    test "storage can be reused after destroy" do
      storage = TS.create()

      TS.set(storage, 0, "key1", "value1")
      TS.destroy(storage)

      TS.set(storage, 0, "key2", "value2")
      assert "value2" == TS.get(storage, 0, "key2")
      assert nil == TS.get(storage, 0, "key1")
    end
  end

  describe "concurrent access" do
    test "handles concurrent reads and writes" do
      storage = TS.create()

      # Pre-populate
      for i <- 1..10 do
        TS.set(storage, 0, "key#{i}", "value#{i}")
      end

      # Concurrent access from multiple tasks
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            # Each task reads and writes
            TS.set(storage, 0, "task#{i}", "task_value_#{i}")
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
            TS.set(storage, 0, "shared", "value#{i}")
            :ok
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == :ok))

      # Some value should be stored (we don't know which due to race)
      value = TS.get(storage, 0, "shared")
      assert is_binary(value)
      assert String.starts_with?(value, "value")
    end

    test "handles concurrent deletes" do
      storage = TS.create()

      # Pre-populate
      for i <- 1..10 do
        TS.set(storage, 0, "key#{i}", "value#{i}")
      end

      # Concurrent deletes
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            TS.del(storage, 0, "key#{i}")
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == :ok))

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
      TS.set(storage, 0, "binary", binary)

      assert ^binary = TS.get(storage, 0, "binary")
    end

    test "handles large binary values" do
      storage = TS.create()

      # 1MB binary
      large_binary = :crypto.strong_rand_bytes(1024 * 1024)
      TS.set(storage, 0, "large", large_binary)

      assert ^large_binary = TS.get(storage, 0, "large")
    end

    test "different binary values for same key across time" do
      storage = TS.create()

      TS.set(storage, 0, "key", "value1")
      assert "value1" == TS.get(storage, 0, "key")

      TS.set(storage, 0, "key", "value2")
      assert "value2" == TS.get(storage, 0, "key")

      TS.set(storage, 0, "key", <<1, 2, 3>>)
      assert <<1, 2, 3>> == TS.get(storage, 0, "key")
    end
  end

  describe "edge cases" do
    test "handles many keys" do
      storage = TS.create()

      # Store 100 keys
      for i <- 1..100 do
        TS.set(storage, 0, "key#{i}", "value#{i}")
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

      TS.set(storage, 0, key, value)
      assert ^value = TS.get(storage, 0, key)
    end
  end

  describe "zcount/5" do
    test "returns 0 for empty zset" do
      storage = TS.create()
      assert {:ok, 0} == TS.zcount(storage, 0, "nonexistent", 0.0, 10.0)
    end

    test "returns 0 when no elements in range" do
      storage = TS.create()
      {:ok, 3} = TS.zadd(storage, 0, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}])

      # Range before all elements
      assert {:ok, 0} == TS.zcount(storage, 0, "myzset", -10.0, 0.5)

      # Range after all elements
      assert {:ok, 0} == TS.zcount(storage, 0, "myzset", 5.0, 10.0)

      # Range between elements
      assert {:ok, 0} == TS.zcount(storage, 0, "myzset", 1.5, 1.9)
    end

    test "counts all elements when range covers all" do
      storage = TS.create()
      {:ok, _} = TS.zadd(storage, 0, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}, {4.0, "d"}, {5.0, "e"}])

      # Range that covers all elements
      assert {:ok, 5} == TS.zcount(storage, 0, "myzset", 0.0, 10.0)
      assert {:ok, 5} == TS.zcount(storage, 0, "myzset", 1.0, 5.0)
    end

    test "min boundary is inclusive" do
      storage = TS.create()
      {:ok, _} = TS.zadd(storage, 0, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}, {4.0, "d"}, {5.0, "e"}])

      # Min boundary exactly at element - should include it
      assert {:ok, 4} == TS.zcount(storage, 0, "myzset", 2.0, 10.0)
      assert {:ok, 5} == TS.zcount(storage, 0, "myzset", 1.0, 10.0)
      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", 5.0, 10.0)
    end

    test "max boundary is inclusive" do
      storage = TS.create()
      {:ok, _} = TS.zadd(storage, 0, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}, {4.0, "d"}, {5.0, "e"}])

      # Max boundary exactly at element - should include it
      assert {:ok, 3} == TS.zcount(storage, 0, "myzset", 0.0, 3.0)
      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", 0.0, 1.0)
      assert {:ok, 5} == TS.zcount(storage, 0, "myzset", 0.0, 5.0)
    end

    test "both boundaries are inclusive" do
      storage = TS.create()
      {:ok, _} = TS.zadd(storage, 0, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}, {4.0, "d"}, {5.0, "e"}])

      # Both boundaries exactly at elements - should include both
      assert {:ok, 3} == TS.zcount(storage, 0, "myzset", 2.0, 4.0)
      assert {:ok, 5} == TS.zcount(storage, 0, "myzset", 1.0, 5.0)
      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", 3.0, 3.0)
    end

    test "single element exact match" do
      storage = TS.create()
      {:ok, _} = TS.zadd(storage, 0, "myzset", [{2.5, "x"}])

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
      {:ok, _} = TS.zadd(storage, 0, "myzset", [{1.0, "a"}, {2.0, "b1"}, {2.0, "b2"}, {2.0, "b3"}, {3.0, "c"}])

      # Range that includes all elements with score 2.0
      assert {:ok, 3} == TS.zcount(storage, 0, "myzset", 2.0, 2.0)

      # Range that includes elements with score 2.0 and others
      assert {:ok, 3} == TS.zcount(storage, 0, "myzset", 1.5, 2.5)
      assert {:ok, 4} == TS.zcount(storage, 0, "myzset", 2.0, 3.0)
      assert {:ok, 4} == TS.zcount(storage, 0, "myzset", 1.0, 2.0)
    end

    test "negative and positive scores" do
      storage = TS.create()
      {:ok, _} = TS.zadd(storage, 0, "myzset", [{-5.0, "a"}, {-2.0, "b"}, {0.0, "c"}, {2.0, "d"}, {5.0, "e"}])

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
      {:ok, _} = TS.zadd(storage, 0, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}, {4.0, "d"}, {5.0, "e"}])

      # Boundaries between integer scores
      assert {:ok, 2} == TS.zcount(storage, 0, "myzset", 1.5, 3.5)
      assert {:ok, 2} == TS.zcount(storage, 0, "myzset", 0.5, 2.5)
      assert {:ok, 2} == TS.zcount(storage, 0, "myzset", 2.1, 4.9)
    end

    test "inverted range returns 0" do
      storage = TS.create()
      {:ok, _} = TS.zadd(storage, 0, "myzset", [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}])

      # Min > Max should return 0
      assert {:ok, 0} == TS.zcount(storage, 0, "myzset", 3.0, 1.0)
    end

    test "large dataset" do
      storage = TS.create()

      # Create 1000 members with scores from 0 to 999
      members = for i <- 0..999, do: {i * 1.0, "member#{i}"}
      {:ok, _} = TS.zadd(storage, 0, "large_zset", members)

      # Test various ranges
      assert {:ok, 1000} == TS.zcount(storage, 0, "large_zset", 0.0, 999.0)
      assert {:ok, 100} == TS.zcount(storage, 0, "large_zset", 100.0, 199.0)
      assert {:ok, 1} == TS.zcount(storage, 0, "large_zset", 500.0, 500.0)
      assert {:ok, 500} == TS.zcount(storage, 0, "large_zset", 250.0, 749.0)
    end

    test "returns error for wrong type" do
      storage = TS.create()
      :ok = TS.set(storage, 0, "mystring", "value")

      assert {:error, :wrong_type} == TS.zcount(storage, 0, "mystring", 0.0, 10.0)
    end

    test "handles boundary precision with floats" do
      storage = TS.create()
      {:ok, _} = TS.zadd(storage, 0, "myzset", [{1.1, "a"}, {1.5, "b"}, {1.9, "c"}, {2.0, "d"}])

      # Test precise boundaries
      assert {:ok, 3} == TS.zcount(storage, 0, "myzset", 1.1, 1.9)
      assert {:ok, 3} == TS.zcount(storage, 0, "myzset", 1.5, 2.0)
      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", 1.9, 1.9)
    end

    test "empty range at exact score" do
      storage = TS.create()
      {:ok, _} = TS.zadd(storage, 0, "myzset", [{1.0, "a"}, {3.0, "b"}])

      # Range at a score where no element exists
      assert {:ok, 0} == TS.zcount(storage, 0, "myzset", 2.0, 2.0)
    end

    test "very large score values" do
      storage = TS.create()
      {:ok, _} = TS.zadd(storage, 0, "myzset", [{1.0e10, "a"}, {2.0e10, "b"}, {3.0e10, "c"}])

      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", 1.5e10, 2.5e10)
      assert {:ok, 3} == TS.zcount(storage, 0, "myzset", 0.0, 1.0e11)
    end

    test "very small score differences" do
      storage = TS.create()
      {:ok, _} = TS.zadd(storage, 0, "myzset", [{0.001, "a"}, {0.002, "b"}, {0.003, "c"}])

      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", 0.0015, 0.0025)
      assert {:ok, 1} == TS.zcount(storage, 0, "myzset", 0.001, 0.001)
    end
  end
end
