defmodule Vdr.TS.CoreTest do
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
end
