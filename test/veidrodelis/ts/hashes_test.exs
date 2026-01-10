defmodule Vdr.TS.HashesTest do
  use ExUnit.Case, async: true

  alias Vdr.TS

  describe "hfirst/3" do
    test "returns first field from hash" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"c", "3"}, {"a", "1"}, {"b", "2"}]}}])

      assert {:ok, {"a", "1"}} == TS.hfirst(storage, 0, "myhash")
    end

    test "returns nil for empty hash" do
      storage = TS.create()

      assert {:ok, nil} == TS.hfirst(storage, 0, "myhash")
    end

    test "returns nil for nonexistent key" do
      storage = TS.create()

      assert {:ok, nil} == TS.hfirst(storage, 0, "nonexistent")
    end

    test "returns error for wrong type" do
      storage = TS.create()
      [:ok] = TS.tx(storage, [{0, {:set, "mystring", "value"}}])

      assert {:error, :wrong_type} == TS.hfirst(storage, 0, "mystring")
    end

    test "returns first field via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"a", "1"}, {"b", "2"}, {"c", "3"}]}}])

      script = """
      local field, value = ts.hfirst('myhash')
      if field == nil then
        return nil
      else
        return field .. '=' .. value
      end
      """

      assert {:ok, "a=1"} == TS.read_tx(storage, 0, script)
    end

    test "returns nil for empty hash via Lua" do
      storage = TS.create()

      script = """
      local field, value = ts.hfirst('nonexistent')
      return field or 'nil'
      """

      assert {:ok, "nil"} == TS.read_tx(storage, 0, script)
    end
  end

  describe "hlast/3" do
    test "returns last field from hash" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"a", "1"}, {"c", "3"}, {"b", "2"}]}}])

      assert {:ok, {"c", "3"}} == TS.hlast(storage, 0, "myhash")
    end

    test "returns nil for empty hash" do
      storage = TS.create()

      assert {:ok, nil} == TS.hlast(storage, 0, "myhash")
    end

    test "returns nil for nonexistent key" do
      storage = TS.create()

      assert {:ok, nil} == TS.hlast(storage, 0, "nonexistent")
    end

    test "returns error for wrong type" do
      storage = TS.create()
      [:ok] = TS.tx(storage, [{0, {:set, "mystring", "value"}}])

      assert {:error, :wrong_type} == TS.hlast(storage, 0, "mystring")
    end

    test "returns last field via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"a", "1"}, {"b", "2"}, {"c", "3"}]}}])

      script = """
      local field, value = ts.hlast('myhash')
      if field == nil then
        return nil
      else
        return field .. '=' .. value
      end
      """

      assert {:ok, "c=3"} == TS.read_tx(storage, 0, script)
    end
  end

  describe "hnext/4" do
    test "returns next field after given field" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"a", "1"}, {"b", "2"}, {"c", "3"}]}}])

      assert {:ok, {"b", "2"}} == TS.hnext(storage, 0, "myhash", "a")
      assert {:ok, {"c", "3"}} == TS.hnext(storage, 0, "myhash", "b")
    end

    test "returns nil when at the end" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"a", "1"}, {"b", "2"}, {"c", "3"}]}}])

      assert {:ok, nil} == TS.hnext(storage, 0, "myhash", "c")
    end

    test "returns nil for nonexistent key" do
      storage = TS.create()

      assert {:ok, nil} == TS.hnext(storage, 0, "nonexistent", "field")
    end

    test "returns error for wrong type" do
      storage = TS.create()
      [:ok] = TS.tx(storage, [{0, {:set, "mystring", "value"}}])

      assert {:error, :wrong_type} == TS.hnext(storage, 0, "mystring", "field")
    end

    test "navigates through entire hash" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"a", "1"}, {"b", "2"}, {"c", "3"}, {"d", "4"}]}}])

      assert {:ok, {"b", "2"}} = TS.hnext(storage, 0, "myhash", "a")
      assert {:ok, {"c", "3"}} = TS.hnext(storage, 0, "myhash", "b")
      assert {:ok, {"d", "4"}} = TS.hnext(storage, 0, "myhash", "c")
      assert {:ok, nil} = TS.hnext(storage, 0, "myhash", "d")
    end

    test "returns next field via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"a", "1"}, {"b", "2"}, {"c", "3"}]}}])

      script = """
      local field, value = ts.hnext('myhash', 'a')
      if field == nil then
        return nil
      else
        return field .. '=' .. value
      end
      """

      assert {:ok, "b=2"} == TS.read_tx(storage, 0, script)
    end

    test "returns nil at end via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"a", "1"}, {"b", "2"}]}}])

      script = """
      local field, value = ts.hnext('myhash', 'b')
      if field == nil then
        return 'nil'
      else
        return 'not nil'
      end
      """

      assert {:ok, "nil"} == TS.read_tx(storage, 0, script)
    end
  end

  describe "hprev/4" do
    test "returns previous field before given field" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"a", "1"}, {"b", "2"}, {"c", "3"}]}}])

      assert {:ok, {"b", "2"}} == TS.hprev(storage, 0, "myhash", "c")
      assert {:ok, {"a", "1"}} == TS.hprev(storage, 0, "myhash", "b")
    end

    test "returns nil when at the beginning" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"a", "1"}, {"b", "2"}, {"c", "3"}]}}])

      assert {:ok, nil} == TS.hprev(storage, 0, "myhash", "a")
    end

    test "returns nil for nonexistent key" do
      storage = TS.create()

      assert {:ok, nil} == TS.hprev(storage, 0, "nonexistent", "field")
    end

    test "returns error for wrong type" do
      storage = TS.create()
      [:ok] = TS.tx(storage, [{0, {:set, "mystring", "value"}}])

      assert {:error, :wrong_type} == TS.hprev(storage, 0, "mystring", "field")
    end

    test "navigates through entire hash backwards" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"a", "1"}, {"b", "2"}, {"c", "3"}, {"d", "4"}]}}])

      assert {:ok, {"c", "3"}} = TS.hprev(storage, 0, "myhash", "d")
      assert {:ok, {"b", "2"}} = TS.hprev(storage, 0, "myhash", "c")
      assert {:ok, {"a", "1"}} = TS.hprev(storage, 0, "myhash", "b")
      assert {:ok, nil} = TS.hprev(storage, 0, "myhash", "a")
    end

    test "returns previous field via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"a", "1"}, {"b", "2"}, {"c", "3"}]}}])

      script = """
      local field, value = ts.hprev('myhash', 'c')
      if field == nil then
        return nil
      else
        return field .. '=' .. value
      end
      """

      assert {:ok, "b=2"} == TS.read_tx(storage, 0, script)
    end

    test "returns nil at beginning via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"a", "1"}, {"b", "2"}]}}])

      script = """
      local field, value = ts.hprev('myhash', 'a')
      if field == nil then
        return 'nil'
      else
        return 'not nil'
      end
      """

      assert {:ok, "nil"} == TS.read_tx(storage, 0, script)
    end
  end

  describe "hash navigation integration" do
    test "traverse entire hash forward with hnext" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"a", "1"}, {"b", "2"}, {"c", "3"}]}}])

      # Start from first
      {:ok, {field1, value1}} = TS.hfirst(storage, 0, "myhash")
      assert field1 == "a"
      assert value1 == "1"

      {:ok, {field2, value2}} = TS.hnext(storage, 0, "myhash", field1)
      assert field2 == "b"
      assert value2 == "2"

      {:ok, {field3, value3}} = TS.hnext(storage, 0, "myhash", field2)
      assert field3 == "c"
      assert value3 == "3"

      {:ok, nil_result} = TS.hnext(storage, 0, "myhash", field3)
      assert nil_result == nil
    end

    test "traverse entire hash backward with hprev" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"a", "1"}, {"b", "2"}, {"c", "3"}]}}])

      # Start from last
      {:ok, {field1, value1}} = TS.hlast(storage, 0, "myhash")
      assert field1 == "c"
      assert value1 == "3"

      {:ok, {field2, value2}} = TS.hprev(storage, 0, "myhash", field1)
      assert field2 == "b"
      assert value2 == "2"

      {:ok, {field3, value3}} = TS.hprev(storage, 0, "myhash", field2)
      assert field3 == "a"
      assert value3 == "1"

      {:ok, nil_result} = TS.hprev(storage, 0, "myhash", field3)
      assert nil_result == nil
    end

    test "traverse hash via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"a", "1"}, {"b", "2"}, {"c", "3"}]}}])

      script = """
      local result = {}
      local field, value = ts.hfirst('myhash')
      while field do
        table.insert(result, field .. '=' .. value)
        field, value = ts.hnext('myhash', field)
      end
      return table.concat(result, ',')
      """

      assert {:ok, "a=1,b=2,c=3"} == TS.read_tx(storage, 0, script)
    end

    test "traverse hash backward via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:hmset, "myhash", [{"a", "1"}, {"b", "2"}, {"c", "3"}]}}])

      script = """
      local result = {}
      local field, value = ts.hlast('myhash')
      while field do
        table.insert(result, field .. '=' .. value)
        field, value = ts.hprev('myhash', field)
      end
      return table.concat(result, ',')
      """

      assert {:ok, "c=3,b=2,a=1"} == TS.read_tx(storage, 0, script)
    end
  end
end
