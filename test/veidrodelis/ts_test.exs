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

      TS.set(storage1, "key", "value1")
      TS.set(storage2, "key", "value2")

      assert "value1" == TS.get(storage1, "key")
      assert "value2" == TS.get(storage2, "key")
    end
  end

  describe "set/3 and get/2" do
    test "stores and retrieves binary values" do
      storage = TS.create()
      :ok = TS.set(storage, "key", "value")
      assert "value" == TS.get(storage, "key")
    end

    test "stores and retrieves binary data" do
      storage = TS.create()
      data = <<0, 1, 2, 3, 4, 5>>
      :ok = TS.set(storage, "data", data)
      assert ^data = TS.get(storage, "data")
    end

    test "overwrites existing values" do
      storage = TS.create()

      TS.set(storage, "key", "value1")
      assert "value1" == TS.get(storage, "key")

      TS.set(storage, "key", "value2")
      assert "value2" == TS.get(storage, "key")
    end

    test "returns nil for missing keys" do
      storage = TS.create()
      assert nil == TS.get(storage, "missing")
    end

    test "handles binary keys with colons" do
      storage = TS.create()
      TS.set(storage, "key:with:colons", "value")
      assert "value" == TS.get(storage, "key:with:colons")
    end

    test "handles binary keys with slashes" do
      storage = TS.create()
      TS.set(storage, "key/with/slashes", "value")
      assert "value" == TS.get(storage, "key/with/slashes")
    end

    test "handles binary keys with spaces" do
      storage = TS.create()
      TS.set(storage, "key with spaces", "value")
      assert "value" == TS.get(storage, "key with spaces")
    end

    test "handles empty binary key" do
      storage = TS.create()
      TS.set(storage, "", "empty_key")
      assert "empty_key" == TS.get(storage, "")
    end

    test "handles empty binary value" do
      storage = TS.create()
      TS.set(storage, "key", "")
      assert "" == TS.get(storage, "key")
    end

    test "handles UTF-8 binary values" do
      storage = TS.create()
      utf8_value = "Hello, 世界! 🌍"
      TS.set(storage, "utf8", utf8_value)
      assert ^utf8_value = TS.get(storage, "utf8")
    end
  end

  describe "del/2" do
    test "deletes existing keys" do
      storage = TS.create()

      TS.set(storage, "key", "value")
      assert "value" == TS.get(storage, "key")

      :ok = TS.del(storage, "key")
      assert nil == TS.get(storage, "key")
    end

    test "returns :ok for missing keys" do
      storage = TS.create()
      assert :ok == TS.del(storage, "missing")
    end

    test "allows re-setting after deletion" do
      storage = TS.create()

      TS.set(storage, "key", "value1")
      TS.del(storage, "key")
      TS.set(storage, "key", "value2")

      assert "value2" == TS.get(storage, "key")
    end

    test "deleting multiple times is idempotent" do
      storage = TS.create()

      TS.set(storage, "key", "value")
      assert :ok = TS.del(storage, "key")
      assert :ok = TS.del(storage, "key")
      assert :ok = TS.del(storage, "key")
    end
  end

  describe "destroy/1" do
    test "clears all data" do
      storage = TS.create()

      TS.set(storage, "key1", "value1")
      TS.set(storage, "key2", "value2")
      TS.set(storage, "key3", "value3")

      :ok = TS.destroy(storage)

      assert nil == TS.get(storage, "key1")
      assert nil == TS.get(storage, "key2")
      assert nil == TS.get(storage, "key3")
    end

    test "storage can be reused after destroy" do
      storage = TS.create()

      TS.set(storage, "key1", "value1")
      TS.destroy(storage)

      TS.set(storage, "key2", "value2")
      assert "value2" == TS.get(storage, "key2")
      assert nil == TS.get(storage, "key1")
    end
  end

  describe "concurrent access" do
    test "handles concurrent reads and writes" do
      storage = TS.create()

      # Pre-populate
      for i <- 1..10 do
        TS.set(storage, "key#{i}", "value#{i}")
      end

      # Concurrent access from multiple tasks
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            # Each task reads and writes
            TS.set(storage, "task#{i}", "task_value_#{i}")
            TS.get(storage, "key#{i}")
          end)
        end

      results = Task.await_many(tasks)
      assert ["value1", "value2", "value3", "value4", "value5"] == results

      # Verify task writes succeeded
      for i <- 1..5 do
        assert "task_value_#{i}" == TS.get(storage, "task#{i}")
      end
    end

    test "handles concurrent writes to same key" do
      storage = TS.create()

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            TS.set(storage, "shared", "value#{i}")
            :ok
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == :ok))

      # Some value should be stored (we don't know which due to race)
      value = TS.get(storage, "shared")
      assert is_binary(value)
      assert String.starts_with?(value, "value")
    end

    test "handles concurrent deletes" do
      storage = TS.create()

      # Pre-populate
      for i <- 1..10 do
        TS.set(storage, "key#{i}", "value#{i}")
      end

      # Concurrent deletes
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            TS.del(storage, "key#{i}")
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == :ok))

      # All keys should be deleted
      for i <- 1..10 do
        assert nil == TS.get(storage, "key#{i}")
      end
    end
  end

  describe "binary preservation" do
    test "preserves binary data exactly" do
      storage = TS.create()

      binary = <<0, 1, 2, 255, 254, 253>>
      TS.set(storage, "binary", binary)

      assert ^binary = TS.get(storage, "binary")
    end

    test "handles large binary values" do
      storage = TS.create()

      # 1MB binary
      large_binary = :crypto.strong_rand_bytes(1024 * 1024)
      TS.set(storage, "large", large_binary)

      assert ^large_binary = TS.get(storage, "large")
    end

    test "different binary values for same key across time" do
      storage = TS.create()

      TS.set(storage, "key", "value1")
      assert "value1" == TS.get(storage, "key")

      TS.set(storage, "key", "value2")
      assert "value2" == TS.get(storage, "key")

      TS.set(storage, "key", <<1, 2, 3>>)
      assert <<1, 2, 3>> == TS.get(storage, "key")
    end
  end

  describe "edge cases" do
    test "handles many keys" do
      storage = TS.create()

      # Store 100 keys
      for i <- 1..100 do
        TS.set(storage, "key#{i}", "value#{i}")
      end

      # Verify all keys
      for i <- 1..100 do
        assert "value#{i}" == TS.get(storage, "key#{i}")
      end
    end

    test "handles keys and values with null bytes" do
      storage = TS.create()

      key = "key\0with\0nulls"
      value = "value\0with\0nulls"

      TS.set(storage, key, value)
      assert ^value = TS.get(storage, key)
    end
  end
end
