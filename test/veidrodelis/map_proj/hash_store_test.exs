defmodule Vdr.MapProj.HashStoreTest do
  use ExUnit.Case, async: true

  alias Vdr.MapProj.{Hashes, Common}

  setup do
    # Simple decode functions that return values as-is
    config = Hashes.new(fn _key, field -> field end, fn _key, _hkey, value -> value end)
    store = %{}

    {:ok, config: config, store: store}
  end

  describe "new/2" do
    test "creates a HashStore config with the given decode functions" do
      decode_hkey_fun = fn _key, field -> field end
      decode_fun = fn _key, _hkey, value -> value end
      config = Hashes.new(decode_hkey_fun, decode_fun)

      assert %Vdr.MapProj.Hashes{
               decode_hkey_fun: ^decode_hkey_fun,
               decode_fun: ^decode_fun
             } = config
    end
  end

  describe "hset/5" do
    test "sets field-value pairs in a hash", %{config: config, store: store} do
      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "value1"}, {"field2", "value2"}])

      assert Hashes.hget(store, 0, "myhash", "field1") == "value1"
      assert Hashes.hget(store, 0, "myhash", "field2") == "value2"
    end

    test "overwrites existing field values", %{config: config, store: store} do
      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "value1"}])
      assert Hashes.hget(store, 0, "myhash", "field1") == "value1"

      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "new_value"}])
      assert Hashes.hget(store, 0, "myhash", "field1") == "new_value"
    end

    test "supports multiple databases", %{config: config, store: store} do
      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "value_db0"}])
      store = Hashes.hset(store, config, 1, "myhash", [{"field1", "value_db1"}])

      assert Hashes.hget(store, 0, "myhash", "field1") == "value_db0"
      assert Hashes.hget(store, 1, "myhash", "field1") == "value_db1"
    end

    test "sets multiple field-value pairs at once", %{config: config, store: store} do
      store =
        Hashes.hset(store, config, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      assert Hashes.hlen(store, 0, "myhash") == 3
    end

    test "sets empty list of field-value pairs", %{config: config, store: store} do
      store = Hashes.hset(store, config, 0, "myhash", [])

      assert Hashes.hlen(store, 0, "myhash") == 0
    end
  end

  describe "hdel/5" do
    test "removes fields from a hash", %{config: config, store: store} do
      store =
        Hashes.hset(store, config, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      store = Hashes.hdel(store, config, 0, "myhash", ["field2"])

      assert Hashes.hget(store, 0, "myhash", "field1") == "value1"
      assert Hashes.hget(store, 0, "myhash", "field2") == nil
      assert Hashes.hget(store, 0, "myhash", "field3") == "value3"
    end

    test "removing non-existent fields is safe", %{config: config, store: store} do
      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "value1"}])
      store = Hashes.hdel(store, config, 0, "myhash", ["nonexistent"])

      assert Hashes.hget(store, 0, "myhash", "field1") == "value1"
      assert Hashes.hlen(store, 0, "myhash") == 1
    end

    test "removes multiple fields at once", %{config: config, store: store} do
      store =
        Hashes.hset(store, config, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      store = Hashes.hdel(store, config, 0, "myhash", ["field1", "field3"])

      assert Hashes.hget(store, 0, "myhash", "field1") == nil
      assert Hashes.hget(store, 0, "myhash", "field2") == "value2"
      assert Hashes.hget(store, 0, "myhash", "field3") == nil
    end

    test "removes all fields and deletes key", %{config: config, store: store} do
      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "value1"}, {"field2", "value2"}])
      store = Hashes.hdel(store, config, 0, "myhash", ["field1", "field2"])

      assert Hashes.hlen(store, 0, "myhash") == 0
      # Verify key was removed from store
      assert store == %{0 => %{}}
    end
  end

  describe "hget/4" do
    test "gets decoded value for existing field", %{config: config, store: store} do
      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "value1"}])

      assert Hashes.hget(store, 0, "myhash", "field1") == "value1"
    end

    test "returns nil for non-existent field", %{config: config, store: store} do
      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "value1"}])

      assert Hashes.hget(store, 0, "myhash", "nonexistent") == nil
    end

    test "returns nil for non-existent hash", %{store: store} do
      assert Hashes.hget(store, 0, "nonexistent", "field1") == nil
    end
  end

  describe "hget_original/4" do
    test "gets original value for existing field", %{config: config, store: store} do
      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "value1"}])

      assert Hashes.hget_original(store, 0, "myhash", "field1") == "value1"
    end

    test "returns nil for non-existent field", %{config: config, store: store} do
      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "value1"}])

      assert Hashes.hget_original(store, 0, "myhash", "nonexistent") == nil
    end

    test "returns nil for non-existent hash", %{store: store} do
      assert Hashes.hget_original(store, 0, "nonexistent", "field1") == nil
    end

    test "returns original value even when decoded value differs" do
      # Use a decode function that transforms values
      config = Hashes.new(fn _key, field -> field end, fn _key, _hkey, value -> String.upcase(value) end)
      store = %{}

      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "hello"}])

      assert Hashes.hget_original(store, 0, "myhash", "field1") == "hello"
      assert Hashes.hget(store, 0, "myhash", "field1") == "HELLO"
    end
  end

  describe "hexists/4" do
    test "returns true when field exists", %{config: config, store: store} do
      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "value1"}])

      assert Hashes.hexists(store, 0, "myhash", "field1") == true
    end

    test "returns false when field doesn't exist", %{config: config, store: store} do
      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "value1"}])

      assert Hashes.hexists(store, 0, "myhash", "nonexistent") == false
    end

    test "returns false for non-existent hash", %{store: store} do
      assert Hashes.hexists(store, 0, "nonexistent", "field1") == false
    end
  end

  describe "hgetall/3" do
    test "returns all field-value pairs", %{config: config, store: store} do
      store =
        Hashes.hset(store, config, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      result = Hashes.hgetall(store, 0, "myhash")
      assert length(result) == 3

      result_map = Map.new(result)
      assert result_map["field1"] == "value1"
      assert result_map["field2"] == "value2"
      assert result_map["field3"] == "value3"
    end

    test "returns empty list for non-existent hash", %{store: store} do
      assert Hashes.hgetall(store, 0, "nonexistent") == []
    end

    test "returns decoded values" do
      # Use a decode function that transforms values
      config = Hashes.new(fn _key, field -> field end, fn _key, _hkey, value -> String.upcase(value) end)
      store = %{}

      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "hello"}])

      result = Hashes.hgetall(store, 0, "myhash")
      assert result == [{"field1", "HELLO"}]
    end
  end

  describe "hkeys/3" do
    test "returns all field names", %{config: config, store: store} do
      store =
        Hashes.hset(store, config, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      keys = Hashes.hkeys(store, 0, "myhash")
      assert Enum.sort(keys) == ["field1", "field2", "field3"]
    end

    test "returns empty list for non-existent hash", %{store: store} do
      assert Hashes.hkeys(store, 0, "nonexistent") == []
    end
  end

  describe "hvals/3" do
    test "returns all values", %{config: config, store: store} do
      store =
        Hashes.hset(store, config, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      vals = Hashes.hvals(store, 0, "myhash")
      assert Enum.sort(vals) == ["value1", "value2", "value3"]
    end

    test "returns empty list for non-existent hash", %{store: store} do
      assert Hashes.hvals(store, 0, "nonexistent") == []
    end

    test "returns decoded values" do
      # Use a decode function that transforms values
      config = Hashes.new(fn _key, field -> field end, fn _key, _hkey, value -> String.upcase(value) end)
      store = %{}

      store =
        Hashes.hset(store, config, 0, "myhash", [
          {"field1", "hello"},
          {"field2", "world"}
        ])

      vals = Hashes.hvals(store, 0, "myhash")
      assert Enum.sort(vals) == ["HELLO", "WORLD"]
    end
  end

  describe "hlen/3" do
    test "returns the number of fields", %{config: config, store: store} do
      store =
        Hashes.hset(store, config, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      assert Hashes.hlen(store, 0, "myhash") == 3
    end

    test "returns 0 for non-existent hash", %{store: store} do
      assert Hashes.hlen(store, 0, "nonexistent") == 0
    end

    test "returns 0 after all fields are removed", %{config: config, store: store} do
      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "value1"}])
      store = Hashes.hdel(store, config, 0, "myhash", ["field1"])

      assert Hashes.hlen(store, 0, "myhash") == 0
    end
  end

  describe "del/3" do
    test "deletes an entire hash", %{config: config, store: store} do
      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "value1"}, {"field2", "value2"}])
      assert Hashes.hlen(store, 0, "myhash") == 2

      store = Common.del(store, 0, "myhash")

      assert Hashes.hlen(store, 0, "myhash") == 0
      assert Hashes.hgetall(store, 0, "myhash") == []
    end

    test "handles deleting non-existent hash", %{store: store} do
      store = Common.del(store, 0, "nonexistent")
      assert store == %{}
    end

    test "only deletes specified database and key", %{config: config, store: store} do
      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "value1"}])
      store = Hashes.hset(store, config, 1, "myhash", [{"field1", "value2"}])
      store = Hashes.hset(store, config, 0, "other", [{"field1", "value3"}])

      store = Common.del(store, 0, "myhash")

      assert Hashes.hlen(store, 0, "myhash") == 0
      assert Hashes.hlen(store, 1, "myhash") == 1
      assert Hashes.hlen(store, 0, "other") == 1
    end
  end

  describe "decode functions" do
    test "uses custom decode_hkey function" do
      # Decode function that uppercases field names
      config = Hashes.new(fn _key, field -> String.upcase(field) end, fn _key, _hkey, value -> value end)
      store = %{}

      store = Hashes.hset(store, config, 0, "myhash", [{"field1", "value1"}, {"field2", "value2"}])

      # Access using decoded hkey
      assert Hashes.hget(store, 0, "myhash", "FIELD1") == "value1"
      assert Hashes.hget(store, 0, "myhash", "FIELD2") == "value2"

      # Original field names don't work
      assert Hashes.hget(store, 0, "myhash", "field1") == nil

      keys = Hashes.hkeys(store, 0, "myhash")
      assert Enum.sort(keys) == ["FIELD1", "FIELD2"]
    end

    test "decode_hkey receives key for context" do
      # Decode function that includes key prefix
      config = Hashes.new(fn key, field -> {key, field} end, fn _key, _hkey, value -> value end)
      store = %{}

      store = Hashes.hset(store, config, 0, "hash1", [{"field1", "value1"}])
      store = Hashes.hset(store, config, 0, "hash2", [{"field1", "value2"}])

      # Decoded hkeys include the hash key
      assert Hashes.hget(store, 0, "hash1", {"hash1", "field1"}) == "value1"
      assert Hashes.hget(store, 0, "hash2", {"hash2", "field1"}) == "value2"
    end

    test "decode_fun receives key and hkey" do
      # Decode function that includes both key and hkey in result
      config = Hashes.new(
        fn _key, field -> field end,
        fn key, hkey, value -> {key, hkey, value} end
      )

      store = %{}

      store = Hashes.hset(store, config, 0, "hash1", [{"field1", "value1"}])

      assert Hashes.hget(store, 0, "hash1", "field1") == {"hash1", "field1", "value1"}
    end
  end

  describe "select_stream/4" do
    test "streams entries matching filter function", %{config: config, store: store} do
      store =
        Hashes.hset(store, config, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      # Filter entries where hkey is "field2"
      filter_fun = fn {hkey, _} -> hkey == "field2" end

      result =
        store
        |> Hashes.select_stream(0, "myhash", filter_fun)
        |> Enum.to_list()

      assert length(result) == 1
      assert [{{0, "myhash", :hset, "field2"}, {"value2", "value2"}}] = result
    end

    test "returns empty stream for non-existent hash", %{store: store} do
      filter_fun = fn _ -> true end

      result =
        store
        |> Hashes.select_stream(0, "nonexistent", filter_fun)
        |> Enum.to_list()

      assert result == []
    end

    test "streams lazily", %{config: config, store: store} do
      fields = for i <- 1..100, do: {"field#{i}", "value#{i}"}
      store = Hashes.hset(store, config, 0, "myhash", fields)

      # Match all and take only first 5
      filter_fun = fn _ -> true end

      result =
        store
        |> Hashes.select_stream(0, "myhash", filter_fun)
        |> Stream.take(5)
        |> Enum.to_list()

      assert length(result) == 5
    end
  end

  describe "select_rev_stream/4" do
    test "streams entries in reverse order", %{config: config, store: store} do
      store =
        Hashes.hset(store, config, 0, "myhash", [
          {"field1", "value1"},
          {"field2", "value2"},
          {"field3", "value3"}
        ])

      # Filter all entries
      filter_fun = fn _ -> true end

      result =
        store
        |> Hashes.select_rev_stream(0, "myhash", filter_fun)
        |> Enum.to_list()

      forward_result =
        store
        |> Hashes.select_stream(0, "myhash", filter_fun)
        |> Enum.to_list()

      # Reverse stream should be reverse of forward stream
      assert result == Enum.reverse(forward_result)
    end

    test "returns empty stream for non-existent hash", %{store: store} do
      filter_fun = fn _ -> true end

      result =
        store
        |> Hashes.select_rev_stream(0, "nonexistent", filter_fun)
        |> Enum.to_list()

      assert result == []
    end
  end
end
