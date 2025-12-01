defmodule Vdr.HashStoreTest do
  use ExUnit.Case, async: true

  alias Vdr.{HashStore, CommonStore}

  setup do
    # Simple decode functions that return values as-is
    decode_hkey_fun = fn _key, field -> field end
    decode_fun = fn _key, _hkey, value -> value end

    # Create shared ETS table
    tid = :ets.new(:test_store, [:set, :public])

    store = HashStore.new(tid, decode_hkey_fun, decode_fun)

    on_exit(fn ->
      try do
        :ets.delete(tid)
      rescue
        ArgumentError -> :ok
      end
    end)

    {:ok, store: store, tid: tid}
  end

  describe "new/3" do
    test "creates a HashStore with the given ETS table" do
      decode_hkey_fun = fn _key, field -> field end
      decode_fun = fn _key, _hkey, value -> value end
      tid = :ets.new(:test_store, [:set, :public])
      store = HashStore.new(tid, decode_hkey_fun, decode_fun)

      assert %HashStore{
               tid: ^tid,
               decode_hkey_fun: ^decode_hkey_fun,
               decode_fun: ^decode_fun
             } = store

      assert is_reference(tid)
      assert :ets.info(tid) != :undefined

      # Clean up
      :ets.delete(tid)
    end
  end

  describe "hset/4" do
    test "sets field-value pairs in a hash", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "value1"}, {"field2", "value2"}])

      assert HashStore.hget(store, 0, "myhash", "field1") == "value1"
      assert HashStore.hget(store, 0, "myhash", "field2") == "value2"
    end

    test "overwrites existing field values", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "value1"}])
      assert HashStore.hget(store, 0, "myhash", "field1") == "value1"

      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "new_value"}])
      assert HashStore.hget(store, 0, "myhash", "field1") == "new_value"
    end

    test "supports multiple databases", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "value_db0"}])
      :ok = HashStore.hset(store, 1, "myhash", [{"field1", "value_db1"}])

      assert HashStore.hget(store, 0, "myhash", "field1") == "value_db0"
      assert HashStore.hget(store, 1, "myhash", "field1") == "value_db1"
    end

    test "sets multiple field-value pairs at once", %{store: store} do
      :ok =
        HashStore.hset(store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      assert HashStore.hlen(store, 0, "myhash") == 3
    end

    test "sets empty list of field-value pairs", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [])

      assert HashStore.hlen(store, 0, "myhash") == 0
    end
  end

  describe "hdel/4" do
    test "removes fields from a hash", %{store: store} do
      :ok =
        HashStore.hset(store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      :ok = HashStore.hdel(store, 0, "myhash", ["field2"])

      assert HashStore.hget(store, 0, "myhash", "field1") == "value1"
      assert HashStore.hget(store, 0, "myhash", "field2") == nil
      assert HashStore.hget(store, 0, "myhash", "field3") == "value3"
    end

    test "removing non-existent fields is safe", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "value1"}])
      :ok = HashStore.hdel(store, 0, "myhash", ["nonexistent"])

      assert HashStore.hget(store, 0, "myhash", "field1") == "value1"
      assert HashStore.hlen(store, 0, "myhash") == 1
    end

    test "removes multiple fields at once", %{store: store} do
      :ok =
        HashStore.hset(store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      :ok = HashStore.hdel(store, 0, "myhash", ["field1", "field3"])

      assert HashStore.hget(store, 0, "myhash", "field1") == nil
      assert HashStore.hget(store, 0, "myhash", "field2") == "value2"
      assert HashStore.hget(store, 0, "myhash", "field3") == nil
    end

    test "removes all fields", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "value1"}, {"field2", "value2"}])
      :ok = HashStore.hdel(store, 0, "myhash", ["field1", "field2"])

      assert HashStore.hlen(store, 0, "myhash") == 0
    end
  end

  describe "hget/4" do
    test "gets decoded value for existing field", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "value1"}])

      assert HashStore.hget(store, 0, "myhash", "field1") == "value1"
    end

    test "returns nil for non-existent field", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "value1"}])

      assert HashStore.hget(store, 0, "myhash", "nonexistent") == nil
    end

    test "returns nil for non-existent hash", %{store: store} do
      assert HashStore.hget(store, 0, "nonexistent", "field1") == nil
    end
  end

  describe "hget_original/4" do
    test "gets original value for existing field", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "value1"}])

      assert HashStore.hget_original(store, 0, "myhash", "field1") == "value1"
    end

    test "returns nil for non-existent field", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "value1"}])

      assert HashStore.hget_original(store, 0, "myhash", "nonexistent") == nil
    end

    test "returns nil for non-existent hash", %{store: store} do
      assert HashStore.hget_original(store, 0, "nonexistent", "field1") == nil
    end

    test "returns original value even when decoded value differs", %{tid: tid} do
      # Use a decode function that transforms values
      decode_hkey_fun = fn _key, field -> field end
      decode_fun = fn _key, _hkey, value -> String.upcase(value) end
      store = HashStore.new(tid, decode_hkey_fun, decode_fun)

      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "hello"}])

      assert HashStore.hget_original(store, 0, "myhash", "field1") == "hello"
      assert HashStore.hget(store, 0, "myhash", "field1") == "HELLO"
    end
  end

  describe "hexists/4" do
    test "returns true when field exists", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "value1"}])

      assert HashStore.hexists(store, 0, "myhash", "field1") == true
    end

    test "returns false when field doesn't exist", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "value1"}])

      assert HashStore.hexists(store, 0, "myhash", "nonexistent") == false
    end

    test "returns false for non-existent hash", %{store: store} do
      assert HashStore.hexists(store, 0, "nonexistent", "field1") == false
    end
  end

  describe "hgetall/3" do
    test "returns all field-value pairs from a hash", %{store: store} do
      :ok =
        HashStore.hset(store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      all = HashStore.hgetall(store, 0, "myhash")
      assert length(all) == 3
      assert Enum.sort(all) == [{"field1", "value1"}, {"field2", "value2"}, {"field3", "value3"}]
    end

    test "returns empty list for non-existent hash", %{store: store} do
      all = HashStore.hgetall(store, 0, "nonexistent")
      assert all == []
    end

    test "returns empty list for empty hash", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "value1"}])
      :ok = HashStore.hdel(store, 0, "myhash", ["field1"])

      all = HashStore.hgetall(store, 0, "myhash")
      assert all == []
    end
  end

  describe "hkeys/3" do
    test "returns all fields from a hash", %{store: store} do
      :ok =
        HashStore.hset(store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      keys = HashStore.hkeys(store, 0, "myhash")
      assert Enum.sort(keys) == ["field1", "field2", "field3"]
    end

    test "returns empty list for non-existent hash", %{store: store} do
      keys = HashStore.hkeys(store, 0, "nonexistent")
      assert keys == []
    end
  end

  describe "hvals/3" do
    test "returns all values from a hash", %{store: store} do
      :ok =
        HashStore.hset(store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      vals = HashStore.hvals(store, 0, "myhash")
      assert Enum.sort(vals) == ["value1", "value2", "value3"]
    end

    test "returns empty list for non-existent hash", %{store: store} do
      vals = HashStore.hvals(store, 0, "nonexistent")
      assert vals == []
    end
  end

  describe "hlen/3" do
    test "returns the number of fields in a hash", %{store: store} do
      :ok =
        HashStore.hset(store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      assert HashStore.hlen(store, 0, "myhash") == 3
    end

    test "returns 0 for non-existent hash", %{store: store} do
      assert HashStore.hlen(store, 0, "nonexistent") == 0
    end

    test "returns 0 for empty hash", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "value1"}])
      :ok = HashStore.hdel(store, 0, "myhash", ["field1"])

      assert HashStore.hlen(store, 0, "myhash") == 0
    end

    test "counts correctly with overwrites", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "value1"}])
      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "new_value"}])

      assert HashStore.hlen(store, 0, "myhash") == 1
    end
  end

  describe "del/3" do
    test "deletes an entire hash", %{store: store, tid: tid} do
      :ok =
        HashStore.hset(store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"}
        ])

      assert HashStore.hlen(store, 0, "myhash") == 2

      :ok = CommonStore.del(tid, 0, "myhash")

      assert HashStore.hlen(store, 0, "myhash") == 0
      assert HashStore.hgetall(store, 0, "myhash") == []
    end

    test "only deletes specified database and key", %{store: store, tid: tid} do
      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "value1"}])
      :ok = HashStore.hset(store, 1, "myhash", [{"field1", "value1"}])
      :ok = HashStore.hset(store, 0, "other", [{"field1", "value1"}])

      :ok = CommonStore.del(tid, 0, "myhash")

      assert HashStore.hlen(store, 0, "myhash") == 0
      assert HashStore.hlen(store, 1, "myhash") == 1
      assert HashStore.hlen(store, 0, "other") == 1
    end
  end

  describe "decode_hkey function" do
    test "uses custom decode_hkey function for ordering" do
      # Decode function that converts to uppercase for case-insensitive ordering
      decode_hkey_fun = fn _key, field -> String.upcase(field) end
      decode_fun = fn _key, _hkey, value -> value end

      tid = :ets.new(:test_store, [:set, :public])
      store = HashStore.new(tid, decode_hkey_fun, decode_fun)

      :ok =
        HashStore.hset(store, 0, "myhash", [
          {"apple", "fruit1"},
          {"BANANA", "fruit2"},
          {"Cherry", "fruit3"}
        ])

      # Fields are stored by their decoded (uppercased) keys
      keys = HashStore.hkeys(store, 0, "myhash")
      assert Enum.sort(keys) == ["APPLE", "BANANA", "CHERRY"]

      # Setting "APPLE" again should overwrite (same decoded hkey)
      :ok = HashStore.hset(store, 0, "myhash", [{"APPLE", "new_fruit"}])
      assert HashStore.hlen(store, 0, "myhash") == 3
      # Note: hkeys returns the decoded_hkey, so "APPLE" is stored once

      # Clean up
      :ets.delete(tid)
    end

    test "decode_hkey function receives key for context" do
      # Decode function that includes key prefix
      decode_hkey_fun = fn key, field -> {key, field} end
      decode_fun = fn _key, _hkey, value -> value end

      tid = :ets.new(:test_store, [:set, :public])
      store = HashStore.new(tid, decode_hkey_fun, decode_fun)

      :ok = HashStore.hset(store, 0, "hash1", [{"field1", "value1"}])
      :ok = HashStore.hset(store, 0, "hash2", [{"field1", "value2"}])

      keys_hash1 = HashStore.hkeys(store, 0, "hash1")
      keys_hash2 = HashStore.hkeys(store, 0, "hash2")

      # Decoded hkeys include the key
      assert keys_hash1 == [{"hash1", "field1"}]
      assert keys_hash2 == [{"hash2", "field1"}]

      # Clean up
      :ets.delete(tid)
    end
  end

  describe "decode function" do
    test "uses custom decode function for values" do
      # Decode value function that parses integers
      decode_hkey_fun = fn _key, field -> field end

      decode_fun = fn _key, _hkey, value ->
        case Integer.parse(value) do
          {num, ""} -> num
          _ -> value
        end
      end

      tid = :ets.new(:test_store, [:set, :public])
      store = HashStore.new(tid, decode_hkey_fun, decode_fun)

      :ok =
        HashStore.hset(store, 0, "myhash", [
          {"count1", "10"},
          {"count2", "20"},
          {"name", "test"}
        ])

      # Values are decoded
      assert HashStore.hget(store, 0, "myhash", "count1") == 10
      assert HashStore.hget(store, 0, "myhash", "count2") == 20
      assert HashStore.hget(store, 0, "myhash", "name") == "test"

      # Clean up
      :ets.delete(tid)
    end

    test "decode function receives key and hkey for context" do
      decode_hkey_fun = fn _key, field -> field end

      # Decode value function that creates a tuple with context
      decode_fun = fn key, hkey, value ->
        {key, hkey, value}
      end

      tid = :ets.new(:test_store, [:set, :public])
      store = HashStore.new(tid, decode_hkey_fun, decode_fun)

      :ok = HashStore.hset(store, 0, "myhash", [{"field1", "value1"}])

      # Decoded value includes key and hkey
      assert HashStore.hget(store, 0, "myhash", "field1") == {"myhash", "field1", "value1"}

      # Clean up
      :ets.delete(tid)
    end
  end

  describe "hash operations with different keys" do
    test "operations work correctly across different hash names", %{store: store} do
      :ok = HashStore.hset(store, 0, "user:1", [{"name", "Alice"}, {"age", "30"}])
      :ok = HashStore.hset(store, 0, "user:2", [{"name", "Bob"}, {"age", "25"}])

      assert HashStore.hlen(store, 0, "user:1") == 2
      assert HashStore.hlen(store, 0, "user:2") == 2

      assert HashStore.hget(store, 0, "user:1", "name") == "Alice"
      assert HashStore.hget(store, 0, "user:2", "name") == "Bob"
    end
  end

  describe "large hash operations" do
    test "handles large hashes efficiently", %{store: store} do
      # Create a large hash
      large_hash = for i <- 1..1000, do: {"field_#{i}", "value_#{i}"}

      :ok = HashStore.hset(store, 0, "large_hash", large_hash)

      assert HashStore.hlen(store, 0, "large_hash") == 1000

      # Get all should return all fields
      all = HashStore.hgetall(store, 0, "large_hash")
      assert length(all) == 1000

      # Delete half of them
      fields_to_delete = for i <- 1..500, do: "field_#{i}"
      :ok = HashStore.hdel(store, 0, "large_hash", fields_to_delete)

      assert HashStore.hlen(store, 0, "large_hash") == 500
    end
  end

  describe "edge cases" do
    test "handles empty field names", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [{"", "empty_field_value"}])

      assert HashStore.hget(store, 0, "myhash", "") == "empty_field_value"
      assert HashStore.hexists(store, 0, "myhash", "") == true
    end

    test "handles empty values", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [{"field1", ""}])

      assert HashStore.hget(store, 0, "myhash", "field1") == ""
      assert HashStore.hexists(store, 0, "myhash", "field1") == true
    end

    test "handles binary field names and values", %{store: store} do
      :ok = HashStore.hset(store, 0, "myhash", [{<<1, 2, 3>>, <<4, 5, 6>>}])

      assert HashStore.hget(store, 0, "myhash", <<1, 2, 3>>) == <<4, 5, 6>>
    end
  end
end
