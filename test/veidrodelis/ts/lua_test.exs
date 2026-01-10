defmodule Vdr.TS.LuaTest do
  use ExUnit.Case, async: true

  alias Vdr.TS

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

      # Missing closing paren
      script = "return ts.get('key'"
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
      # Missing closing paren
      script = "return ts.get('key'"

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
