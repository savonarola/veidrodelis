defmodule Vdr.HashStoreTest do
  use ExUnit.Case, async: true

  alias Vdr.ETSProj.Write.{Hashes, Common}
  alias Vdr.ETSProj.Read

  setup do
    # Simple decode functions that return values as-is
    decode_hkey_fun = fn _key, field -> field end
    decode_fun = fn _key, _hkey, value -> value end

    # Create shared ETS table
    tid = :ets.new(:test_store, [:set, :public])

    write_store = Hashes.new(tid, decode_hkey_fun, decode_fun)
    read_store = Read.Hashes.new(tid)

    on_exit(fn ->
      try do
        :ets.delete(tid)
      rescue
        ArgumentError -> :ok
      end
    end)

    {:ok, write_store: write_store, read_store: read_store, tid: tid}
  end

  describe "new/3" do
    test "creates a HashStore with the given ETS table" do
      decode_hkey_fun = fn _key, field -> field end
      decode_fun = fn _key, _hkey, value -> value end
      tid = :ets.new(:test_store, [:set, :public])
      write_store = Hashes.new(tid, decode_hkey_fun, decode_fun)

      assert %Vdr.ETSProj.Write.Hashes{
               tid: ^tid,
               decode_hkey_fun: ^decode_hkey_fun,
               decode_fun: ^decode_fun
             } = write_store

      assert is_reference(tid)
      assert :ets.info(tid) != :undefined

      # Clean up
      :ets.delete(tid)
    end
  end

  describe "hset/4" do
    test "sets field-value pairs in a hash", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value1"}, {"field2", "value2"}])

      assert Read.Hashes.hget(read_store, 0, "myhash", "field1") == "value1"
      assert Read.Hashes.hget(read_store, 0, "myhash", "field2") == "value2"
    end

    test "overwrites existing field values", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value1"}])
      assert Read.Hashes.hget(read_store, 0, "myhash", "field1") == "value1"

      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "new_value"}])
      assert Read.Hashes.hget(read_store, 0, "myhash", "field1") == "new_value"
    end

    test "supports multiple databases", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value_db0"}])
      :ok = Hashes.hset(write_store, 1, "myhash", [{"field1", "value_db1"}])

      assert Read.Hashes.hget(read_store, 0, "myhash", "field1") == "value_db0"
      assert Read.Hashes.hget(read_store, 1, "myhash", "field1") == "value_db1"
    end

    test "sets multiple field-value pairs at once", %{write_store: write_store, read_store: read_store} do
      :ok =
        Hashes.hset(write_store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      assert Read.Hashes.hlen(read_store, 0, "myhash") == 3
    end

    test "sets empty list of field-value pairs", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [])

      assert Read.Hashes.hlen(read_store, 0, "myhash") == 0
    end
  end

  describe "hdel/4" do
    test "removes fields from a hash", %{write_store: write_store, read_store: read_store} do
      :ok =
        Hashes.hset(write_store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      :ok = Hashes.hdel(write_store, 0, "myhash", ["field2"])

      assert Read.Hashes.hget(read_store, 0, "myhash", "field1") == "value1"
      assert Read.Hashes.hget(read_store, 0, "myhash", "field2") == nil
      assert Read.Hashes.hget(read_store, 0, "myhash", "field3") == "value3"
    end

    test "removing non-existent fields is safe", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value1"}])
      :ok = Hashes.hdel(write_store, 0, "myhash", ["nonexistent"])

      assert Read.Hashes.hget(read_store, 0, "myhash", "field1") == "value1"
      assert Read.Hashes.hlen(read_store, 0, "myhash") == 1
    end

    test "removes multiple fields at once", %{write_store: write_store, read_store: read_store} do
      :ok =
        Hashes.hset(write_store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      :ok = Hashes.hdel(write_store, 0, "myhash", ["field1", "field3"])

      assert Read.Hashes.hget(read_store, 0, "myhash", "field1") == nil
      assert Read.Hashes.hget(read_store, 0, "myhash", "field2") == "value2"
      assert Read.Hashes.hget(read_store, 0, "myhash", "field3") == nil
    end

    test "removes all fields", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value1"}, {"field2", "value2"}])
      :ok = Hashes.hdel(write_store, 0, "myhash", ["field1", "field2"])

      assert Read.Hashes.hlen(read_store, 0, "myhash") == 0
    end
  end

  describe "hget/4" do
    test "gets decoded value for existing field", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value1"}])

      assert Read.Hashes.hget(read_store, 0, "myhash", "field1") == "value1"
    end

    test "returns nil for non-existent field", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value1"}])

      assert Read.Hashes.hget(read_store, 0, "myhash", "nonexistent") == nil
    end

    test "returns nil for non-existent hash", %{read_store: read_store} do
      assert Read.Hashes.hget(read_store, 0, "nonexistent", "field1") == nil
    end
  end

  describe "hget_original/4" do
    test "gets original value for existing field", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value1"}])

      assert Read.Hashes.hget_original(read_store, 0, "myhash", "field1") == "value1"
    end

    test "returns nil for non-existent field", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value1"}])

      assert Read.Hashes.hget_original(read_store, 0, "myhash", "nonexistent") == nil
    end

    test "returns nil for non-existent hash", %{read_store: read_store} do
      assert Read.Hashes.hget_original(read_store, 0, "nonexistent", "field1") == nil
    end

    test "returns original value even when decoded value differs", %{tid: tid} do
      # Use a decode function that transforms values
      decode_hkey_fun = fn _key, field -> field end
      decode_fun = fn _key, _hkey, value -> String.upcase(value) end
      write_store = Hashes.new(tid, decode_hkey_fun, decode_fun)
    read_store = Read.Hashes.new(tid)

      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "hello"}])

      assert Read.Hashes.hget_original(read_store, 0, "myhash", "field1") == "hello"
      assert Read.Hashes.hget(read_store, 0, "myhash", "field1") == "HELLO"
    end
  end

  describe "hexists/4" do
    test "returns true when field exists", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value1"}])

      assert Read.Hashes.hexists(read_store, 0, "myhash", "field1") == true
    end

    test "returns false when field doesn't exist", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value1"}])

      assert Read.Hashes.hexists(read_store, 0, "myhash", "nonexistent") == false
    end

    test "returns false for non-existent hash", %{read_store: read_store} do
      assert Read.Hashes.hexists(read_store, 0, "nonexistent", "field1") == false
    end
  end

  describe "hgetall/3" do
    test "returns all field-value pairs from a hash", %{write_store: write_store, read_store: read_store} do
      :ok =
        Hashes.hset(write_store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      all = Read.Hashes.hgetall(read_store, 0, "myhash")
      assert length(all) == 3
      assert Enum.sort(all) == [{"field1", "value1"}, {"field2", "value2"}, {"field3", "value3"}]
    end

    test "returns empty list for non-existent hash", %{read_store: read_store} do
      all = Read.Hashes.hgetall(read_store, 0, "nonexistent")
      assert all == []
    end

    test "returns empty list for empty hash", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value1"}])
      :ok = Hashes.hdel(write_store, 0, "myhash", ["field1"])

      all = Read.Hashes.hgetall(read_store, 0, "myhash")
      assert all == []
    end
  end

  describe "hkeys/3" do
    test "returns all fields from a hash", %{write_store: write_store, read_store: read_store} do
      :ok =
        Hashes.hset(write_store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      keys = Read.Hashes.hkeys(read_store, 0, "myhash")
      assert Enum.sort(keys) == ["field1", "field2", "field3"]
    end

    test "returns empty list for non-existent hash", %{read_store: read_store} do
      keys = Read.Hashes.hkeys(read_store, 0, "nonexistent")
      assert keys == []
    end
  end

  describe "hvals/3" do
    test "returns all values from a hash", %{write_store: write_store, read_store: read_store} do
      :ok =
        Hashes.hset(write_store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      vals = Read.Hashes.hvals(read_store, 0, "myhash")
      assert Enum.sort(vals) == ["value1", "value2", "value3"]
    end

    test "returns empty list for non-existent hash", %{read_store: read_store} do
      vals = Read.Hashes.hvals(read_store, 0, "nonexistent")
      assert vals == []
    end
  end

  describe "hlen/3" do
    test "returns the number of fields in a hash", %{write_store: write_store, read_store: read_store} do
      :ok =
        Hashes.hset(write_store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      assert Read.Hashes.hlen(read_store, 0, "myhash") == 3
    end

    test "returns 0 for non-existent hash", %{read_store: read_store} do
      assert Read.Hashes.hlen(read_store, 0, "nonexistent") == 0
    end

    test "returns 0 for empty hash", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value1"}])
      :ok = Hashes.hdel(write_store, 0, "myhash", ["field1"])

      assert Read.Hashes.hlen(read_store, 0, "myhash") == 0
    end

    test "counts correctly with overwrites", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value1"}])
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "new_value"}])

      assert Read.Hashes.hlen(read_store, 0, "myhash") == 1
    end
  end

  describe "del/3" do
    test "deletes an entire hash", %{write_store: write_store, read_store: read_store, tid: tid} do
      :ok =
        Hashes.hset(write_store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"}
        ])

      assert Read.Hashes.hlen(read_store, 0, "myhash") == 2

      :ok = Common.del(tid, 0, "myhash")

      assert Read.Hashes.hlen(read_store, 0, "myhash") == 0
      assert Read.Hashes.hgetall(read_store, 0, "myhash") == []
    end

    test "only deletes specified database and key", %{write_store: write_store, read_store: read_store, tid: tid} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value1"}])
      :ok = Hashes.hset(write_store, 1, "myhash", [{"field1", "value1"}])
      :ok = Hashes.hset(write_store, 0, "other", [{"field1", "value1"}])

      :ok = Common.del(tid, 0, "myhash")

      assert Read.Hashes.hlen(read_store, 0, "myhash") == 0
      assert Read.Hashes.hlen(read_store, 1, "myhash") == 1
      assert Read.Hashes.hlen(read_store, 0, "other") == 1
    end
  end

  describe "decode_hkey function" do
    test "uses custom decode_hkey function for ordering" do
      # Decode function that converts to uppercase for case-insensitive ordering
      decode_hkey_fun = fn _key, field -> String.upcase(field) end
      decode_fun = fn _key, _hkey, value -> value end

      tid = :ets.new(:test_store, [:set, :public])
      write_store = Hashes.new(tid, decode_hkey_fun, decode_fun)
    read_store = Read.Hashes.new(tid)

      :ok =
        Hashes.hset(write_store, 0, "myhash", [
          {"apple", "fruit1"},
          {"BANANA", "fruit2"},
          {"Cherry", "fruit3"}
        ])

      # Fields are stored by their decoded (uppercased) keys
      keys = Read.Hashes.hkeys(read_store, 0, "myhash")
      assert Enum.sort(keys) == ["APPLE", "BANANA", "CHERRY"]

      # Setting "APPLE" again should overwrite (same decoded hkey)
      :ok = Hashes.hset(write_store, 0, "myhash", [{"APPLE", "new_fruit"}])
      assert Read.Hashes.hlen(read_store, 0, "myhash") == 3
      # Note: hkeys returns the decoded_hkey, so "APPLE" is stored once

      # Clean up
      :ets.delete(tid)
    end

    test "decode_hkey function receives key for context" do
      # Decode function that includes key prefix
      decode_hkey_fun = fn key, field -> {key, field} end
      decode_fun = fn _key, _hkey, value -> value end

      tid = :ets.new(:test_store, [:set, :public])
      write_store = Hashes.new(tid, decode_hkey_fun, decode_fun)
    read_store = Read.Hashes.new(tid)

      :ok = Hashes.hset(write_store, 0, "hash1", [{"field1", "value1"}])
      :ok = Hashes.hset(write_store, 0, "hash2", [{"field1", "value2"}])

      keys_hash1 = Read.Hashes.hkeys(read_store, 0, "hash1")
      keys_hash2 = Read.Hashes.hkeys(read_store, 0, "hash2")

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
      write_store = Hashes.new(tid, decode_hkey_fun, decode_fun)
    read_store = Read.Hashes.new(tid)

      :ok =
        Hashes.hset(write_store, 0, "myhash", [
          {"count1", "10"},
          {"count2", "20"},
          {"name", "test"}
        ])

      # Values are decoded
      assert Read.Hashes.hget(read_store, 0, "myhash", "count1") == 10
      assert Read.Hashes.hget(read_store, 0, "myhash", "count2") == 20
      assert Read.Hashes.hget(read_store, 0, "myhash", "name") == "test"

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
      write_store = Hashes.new(tid, decode_hkey_fun, decode_fun)
    read_store = Read.Hashes.new(tid)

      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value1"}])

      # Decoded value includes key and hkey
      assert Read.Hashes.hget(read_store, 0, "myhash", "field1") == {"myhash", "field1", "value1"}

      # Clean up
      :ets.delete(tid)
    end
  end

  describe "hash operations with different keys" do
    test "operations work correctly across different hash names", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "user:1", [{"name", "Alice"}, {"age", "30"}])
      :ok = Hashes.hset(write_store, 0, "user:2", [{"name", "Bob"}, {"age", "25"}])

      assert Read.Hashes.hlen(read_store, 0, "user:1") == 2
      assert Read.Hashes.hlen(read_store, 0, "user:2") == 2

      assert Read.Hashes.hget(read_store, 0, "user:1", "name") == "Alice"
      assert Read.Hashes.hget(read_store, 0, "user:2", "name") == "Bob"
    end
  end

  describe "large hash operations" do
    test "handles large hashes efficiently", %{write_store: write_store, read_store: read_store} do
      # Create a large hash
      large_hash = for i <- 1..1000, do: {"field_#{i}", "value_#{i}"}

      :ok = Hashes.hset(write_store, 0, "large_hash", large_hash)

      assert Read.Hashes.hlen(read_store, 0, "large_hash") == 1000

      # Get all should return all fields
      all = Read.Hashes.hgetall(read_store, 0, "large_hash")
      assert length(all) == 1000

      # Delete half of them
      fields_to_delete = for i <- 1..500, do: "field_#{i}"
      :ok = Hashes.hdel(write_store, 0, "large_hash", fields_to_delete)

      assert Read.Hashes.hlen(read_store, 0, "large_hash") == 500
    end
  end

  describe "select_stream/4" do
    test "streams hash entries matching a simple hkey equality pattern", %{write_store: write_store, read_store: read_store} do
      :ok =
        Hashes.hset(write_store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      # Match pattern that matches hkey equal to "field2"
      match_pattern = {{:"$1", :"$2"}, [{:==, :"$1", "field2"}]}

      result =
        read_store
        |> Read.Hashes.select_stream(0, "myhash", match_pattern)
        |> Enum.to_list()

      # Should return the entire ETS object
      assert [{{0, "myhash", :hset, "field2"}, {"value2", "value2"}}] = result
    end

    test "streams hash entries matching value pattern", %{write_store: write_store, read_store: read_store} do
      :ok =
        Hashes.hset(write_store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value1"}
        ])

      # Match pattern that matches value equal to "value1"
      match_pattern = {{:"$1", {:"$2", :"$3"}}, [{:==, :"$3", "value1"}]}

      result =
        read_store
        |> Read.Hashes.select_stream(0, "myhash", match_pattern)
        |> Enum.sort()

      # Should return entries with value1
      assert length(result) == 2
      assert Enum.all?(result, fn {_key, {_orig, decoded}} -> decoded == "value1" end)
    end

    test "streams hash entries with numeric pattern", %{} do
      # Use numeric decode function
      decode_hkey_fun = fn _key, field -> field end

      decode_fun = fn _key, _hkey, value ->
        case Integer.parse(value) do
          {num, ""} -> num
          _ -> value
        end
      end

      tid = :ets.new(:test_store, [:set, :public])
      write_store = Hashes.new(tid, decode_hkey_fun, decode_fun)
      read_store = Read.Hashes.new(tid)

      :ok =
        Hashes.hset(write_store, 0, "myhash", [
          {"count1", "10"},
          {"count2", "5"},
          {"count3", "20"},
          {"name", "test"}
        ])

      # Match pattern that matches decoded values > 10
      match_pattern = {{:"$1", {:"$2", :"$3"}}, [{:is_integer, :"$3"}, {:>, :"$3", 10}]}

      result =
        read_store
        |> Read.Hashes.select_stream(0, "myhash", match_pattern)
        |> Enum.to_list()

      # Should match count3 only
      assert [{{0, "myhash", :hset, "count3"}, {"20", 20}}] = result

      :ets.delete(tid)
    end

    test "returns empty stream when no matches", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value1"}])

      # Match pattern that matches hkey equal to "nonexistent"
      match_pattern = {{:"$1", :"$2"}, [{:==, :"$1", "nonexistent"}]}

      result =
        read_store
        |> Read.Hashes.select_stream(0, "myhash", match_pattern)
        |> Enum.to_list()

      assert [] = result
    end

    test "returns empty stream for non-existent hash", %{read_store: read_store} do
      match_pattern = {{:"$1", :"$2"}, [{:==, :"$1", "field1"}]}

      result =
        read_store
        |> Read.Hashes.select_stream(0, "nonexistent", match_pattern)
        |> Enum.to_list()

      assert [] = result
    end

    test "works with match all pattern", %{write_store: write_store, read_store: read_store} do
      :ok =
        Hashes.hset(write_store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      # Match pattern that matches all entries
      match_pattern = {{:"$1", :"$2"}, []}

      result =
        read_store
        |> Read.Hashes.select_stream(0, "myhash", match_pattern)
        |> Enum.to_list()

      assert length(result) == 3
    end

    test "streams lazily", %{write_store: write_store, read_store: read_store} do
      entries = for i <- 1..100, do: {"field_#{i}", "value_#{i}"}
      :ok = Hashes.hset(write_store, 0, "myhash", entries)

      # Match all and take only first 5
      match_pattern = {{:"$1", :"$2"}, []}

      result =
        read_store
        |> Read.Hashes.select_stream(0, "myhash", match_pattern)
        |> Stream.take(5)
        |> Enum.to_list()

      assert length(result) == 5
    end

    test "matches with complex guard conditions", %{write_store: write_store, read_store: read_store} do
      :ok =
        Hashes.hset(write_store, 0, "myhash", [
          {"apple", "fruit"},
          {"banana", "fruit"},
          {"carrot", "vegetable"}
        ])

      # Match pattern that matches hkeys starting with "a" or "b" and value "fruit"
      match_pattern = {
        {:"$1", {:"$2", :"$3"}},
        [
          {:orelse, {:==, :"$1", "apple"}, {:==, :"$1", "banana"}},
          {:==, :"$3", "fruit"}
        ]
      }

      result =
        read_store
        |> Read.Hashes.select_stream(0, "myhash", match_pattern)
        |> Enum.sort()

      assert length(result) == 2
    end
  end

  describe "select_rev_stream/4" do
    test "streams hash entries in reverse order" do
      tid = :ets.new(:test_store, [:ordered_set, :public])
      decode_hkey_fun = fn _key, field -> field end
      decode_fun = fn _key, _hkey, value -> value end
      write_store = Hashes.new(tid, decode_hkey_fun, decode_fun)
      read_store = Read.Hashes.new(tid)

      :ok =
        Hashes.hset(write_store, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      # Match pattern that matches all entries
      match_pattern = {{:"$1", :"$2"}, []}

      result =
        read_store
        |> Read.Hashes.select_rev_stream(0, "myhash", match_pattern)
        |> Enum.to_list()

      forward_result =
        read_store
        |> Read.Hashes.select_stream(0, "myhash", match_pattern)
        |> Enum.to_list()

      # Reverse stream should be reverse of forward stream with ordered_set
      assert result == Enum.reverse(forward_result)

      :ets.delete(tid)
    end

    test "streams numeric hash entries in reverse order", %{} do
      # Use numeric decode function for hkeys
      decode_hkey_fun = fn _key, field ->
        case Integer.parse(field) do
          {num, ""} -> num
          _ -> field
        end
      end

      decode_fun = fn _key, _hkey, value -> value end

      tid = :ets.new(:test_store, [:ordered_set, :public])
      write_store = Hashes.new(tid, decode_hkey_fun, decode_fun)
      read_store = Read.Hashes.new(tid)

      :ok =
        Hashes.hset(write_store, 0, "myhash", [
          {"1", "value1"},
          {"5", "value5"},
          {"10", "value10"},
          {"15", "value15"},
          {"20", "value20"}
        ])

      # Match pattern that matches hkeys > 5
      match_pattern = {{:"$1", :"$2"}, [{:>, :"$1", 5}]}

      result =
        read_store
        |> Read.Hashes.select_rev_stream(0, "myhash", match_pattern)
        |> Enum.map(fn {{_, _, _, hkey}, _} -> hkey end)

      # Should be in descending order with ordered_set
      assert [20, 15, 10] = result

      :ets.delete(tid)
    end

    test "returns empty stream when no matches", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", "value1"}])

      # Match pattern that matches hkey equal to "nonexistent"
      match_pattern = {{:"$1", :"$2"}, [{:==, :"$1", "nonexistent"}]}

      result =
        read_store
        |> Read.Hashes.select_rev_stream(0, "myhash", match_pattern)
        |> Enum.to_list()

      assert [] = result
    end

    test "returns empty stream for non-existent hash", %{read_store: read_store} do
      match_pattern = {{:"$1", :"$2"}, [{:==, :"$1", "field1"}]}

      result =
        read_store
        |> Read.Hashes.select_rev_stream(0, "nonexistent", match_pattern)
        |> Enum.to_list()

      assert [] = result
    end

    test "streams lazily in reverse", %{write_store: write_store, read_store: read_store} do
      entries = for i <- 1..100, do: {"field_#{String.pad_leading("#{i}", 3, "0")}", "value_#{i}"}
      :ok = Hashes.hset(write_store, 0, "myhash", entries)

      # Match all and take only first 5 in reverse order
      match_pattern = {{:"$1", :"$2"}, []}

      result =
        read_store
        |> Read.Hashes.select_rev_stream(0, "myhash", match_pattern)
        |> Stream.take(5)
        |> Enum.to_list()

      assert length(result) == 5
    end
  end

  describe "edge cases" do
    test "handles empty field names", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"", "empty_field_value"}])

      assert Read.Hashes.hget(read_store, 0, "myhash", "") == "empty_field_value"
      assert Read.Hashes.hexists(read_store, 0, "myhash", "") == true
    end

    test "handles empty values", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{"field1", ""}])

      assert Read.Hashes.hget(read_store, 0, "myhash", "field1") == ""
      assert Read.Hashes.hexists(read_store, 0, "myhash", "field1") == true
    end

    test "handles binary field names and values", %{write_store: write_store, read_store: read_store} do
      :ok = Hashes.hset(write_store, 0, "myhash", [{<<1, 2, 3>>, <<4, 5, 6>>}])

      assert Read.Hashes.hget(read_store, 0, "myhash", <<1, 2, 3>>) == <<4, 5, 6>>
    end
  end
end
