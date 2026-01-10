defmodule Vdr.TS.SetsTest do
  use ExUnit.Case, async: true

  alias Vdr.TS

  describe "sfirst/3" do
    test "returns first member from set" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["c", "a", "b"]}}])

      assert {:ok, "a"} == TS.sfirst(storage, 0, "myset")
    end

    test "returns nil for empty set" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", []}}])

      assert {:ok, nil} == TS.sfirst(storage, 0, "myset")
    end

    test "returns nil for nonexistent key" do
      storage = TS.create()

      assert {:ok, nil} == TS.sfirst(storage, 0, "nonexistent")
    end

    test "returns error for wrong type" do
      storage = TS.create()
      [:ok] = TS.tx(storage, [{0, {:set, "mystring", "value"}}])

      assert {:error, :wrong_type} == TS.sfirst(storage, 0, "mystring")
    end

    test "returns first member via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c"]}}])

      script = """
      local member = ts.sfirst('myset')
      return member
      """

      assert {:ok, "a"} == TS.read_tx(storage, 0, script)
    end

    test "returns nil for empty set via Lua" do
      storage = TS.create()

      script = """
      local member = ts.sfirst('nonexistent')
      return member or 'nil'
      """

      assert {:ok, "nil"} == TS.read_tx(storage, 0, script)
    end
  end

  describe "slast/3" do
    test "returns last member from set" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["a", "c", "b"]}}])

      assert {:ok, "c"} == TS.slast(storage, 0, "myset")
    end

    test "returns nil for empty set" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", []}}])

      assert {:ok, nil} == TS.slast(storage, 0, "myset")
    end

    test "returns nil for nonexistent key" do
      storage = TS.create()

      assert {:ok, nil} == TS.slast(storage, 0, "nonexistent")
    end

    test "returns error for wrong type" do
      storage = TS.create()
      [:ok] = TS.tx(storage, [{0, {:set, "mystring", "value"}}])

      assert {:error, :wrong_type} == TS.slast(storage, 0, "mystring")
    end

    test "returns last member via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c"]}}])

      script = """
      local member = ts.slast('myset')
      return member
      """

      assert {:ok, "c"} == TS.read_tx(storage, 0, script)
    end
  end

  describe "snext/4" do
    test "returns next member after given position" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c"]}}])

      assert {:ok, "b"} == TS.snext(storage, 0, "myset", "a")
      assert {:ok, "c"} == TS.snext(storage, 0, "myset", "b")
    end

    test "returns nil when at the end" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c"]}}])

      assert {:ok, nil} == TS.snext(storage, 0, "myset", "c")
    end

    test "returns nil for nonexistent key" do
      storage = TS.create()

      assert {:ok, nil} == TS.snext(storage, 0, "nonexistent", "member")
    end

    test "returns error for wrong type" do
      storage = TS.create()
      [:ok] = TS.tx(storage, [{0, {:set, "mystring", "value"}}])

      assert {:error, :wrong_type} == TS.snext(storage, 0, "mystring", "member")
    end

    test "navigates through entire set" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c", "d"]}}])

      assert {:ok, "b"} = TS.snext(storage, 0, "myset", "a")
      assert {:ok, "c"} = TS.snext(storage, 0, "myset", "b")
      assert {:ok, "d"} = TS.snext(storage, 0, "myset", "c")
      assert {:ok, nil} = TS.snext(storage, 0, "myset", "d")
    end

    test "returns next member via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c"]}}])

      script = """
      local member = ts.snext('myset', 'a')
      return member
      """

      assert {:ok, "b"} == TS.read_tx(storage, 0, script)
    end

    test "returns nil at end via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["a", "b"]}}])

      script = """
      local member = ts.snext('myset', 'b')
      if member == nil then
        return 'nil'
      else
        return 'not nil'
      end
      """

      assert {:ok, "nil"} == TS.read_tx(storage, 0, script)
    end
  end

  describe "sprev/4" do
    test "returns previous member before given position" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c"]}}])

      assert {:ok, "b"} == TS.sprev(storage, 0, "myset", "c")
      assert {:ok, "a"} == TS.sprev(storage, 0, "myset", "b")
    end

    test "returns nil when at the beginning" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c"]}}])

      assert {:ok, nil} == TS.sprev(storage, 0, "myset", "a")
    end

    test "returns nil for nonexistent key" do
      storage = TS.create()

      assert {:ok, nil} == TS.sprev(storage, 0, "nonexistent", "member")
    end

    test "returns error for wrong type" do
      storage = TS.create()
      [:ok] = TS.tx(storage, [{0, {:set, "mystring", "value"}}])

      assert {:error, :wrong_type} == TS.sprev(storage, 0, "mystring", "member")
    end

    test "navigates through entire set backwards" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c", "d"]}}])

      assert {:ok, "c"} = TS.sprev(storage, 0, "myset", "d")
      assert {:ok, "b"} = TS.sprev(storage, 0, "myset", "c")
      assert {:ok, "a"} = TS.sprev(storage, 0, "myset", "b")
      assert {:ok, nil} = TS.sprev(storage, 0, "myset", "a")
    end

    test "returns previous member via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c"]}}])

      script = """
      local member = ts.sprev('myset', 'c')
      return member
      """

      assert {:ok, "b"} == TS.read_tx(storage, 0, script)
    end

    test "returns nil at beginning via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["a", "b"]}}])

      script = """
      local member = ts.sprev('myset', 'a')
      if member == nil then
        return 'nil'
      else
        return 'not nil'
      end
      """

      assert {:ok, "nil"} == TS.read_tx(storage, 0, script)
    end
  end

  describe "set navigation integration" do
    test "traverse entire set forward with snext" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c"]}}])

      # Start from first
      {:ok, member1} = TS.sfirst(storage, 0, "myset")
      assert member1 == "a"

      {:ok, member2} = TS.snext(storage, 0, "myset", member1)
      assert member2 == "b"

      {:ok, member3} = TS.snext(storage, 0, "myset", member2)
      assert member3 == "c"

      {:ok, nil_member} = TS.snext(storage, 0, "myset", member3)
      assert nil_member == nil
    end

    test "traverse entire set backward with sprev" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c"]}}])

      # Start from last
      {:ok, member1} = TS.slast(storage, 0, "myset")
      assert member1 == "c"

      {:ok, member2} = TS.sprev(storage, 0, "myset", member1)
      assert member2 == "b"

      {:ok, member3} = TS.sprev(storage, 0, "myset", member2)
      assert member3 == "a"

      {:ok, nil_member} = TS.sprev(storage, 0, "myset", member3)
      assert nil_member == nil
    end

    test "traverse set via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c"]}}])

      script = """
      local result = {}
      local member = ts.sfirst('myset')
      while member do
        table.insert(result, member)
        member = ts.snext('myset', member)
      end
      return table.concat(result, ',')
      """

      assert {:ok, "a,b,c"} == TS.read_tx(storage, 0, script)
    end

    test "traverse set backward via Lua" do
      storage = TS.create()
      TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c"]}}])

      script = """
      local result = {}
      local member = ts.slast('myset')
      while member do
        table.insert(result, member)
        member = ts.sprev('myset', member)
      end
      return table.concat(result, ',')
      """

      assert {:ok, "c,b,a"} == TS.read_tx(storage, 0, script)
    end
  end
end
