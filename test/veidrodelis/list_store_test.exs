defmodule Vdr.ListStoreTest do
  use ExUnit.Case, async: true

  alias Vdr.ETSProj.Write.{Lists, Common}
  alias Vdr.ETSProj.Read

  setup do
    # Create a unique ETS table for each test
    tid = :ets.new(:test_list_store, [:ordered_set, :public])
    decode_fun = fn _key, val -> val end
    write_store = Lists.new(tid, decode_fun)
    read_store = Read.Lists.new(tid)
    
    on_exit(fn ->
      # Check if table still exists before deleting
      if tid in :ets.all() do
        :ets.delete(tid)
      end
    end)
    
    {:ok, write_store: write_store, read_store: read_store, tid: tid}
  end

  describe "new/2" do
    test "creates a new list write_store with decode function" do
      tid = :ets.new(:test, [:ordered_set, :public])
      decode_fun = fn _key, val -> {:decoded, val} end
      write_store = Lists.new(tid, decode_fun)

      assert %Vdr.ETSProj.Write.Lists{tid: ^tid, decode_fun: ^decode_fun} = write_store
      :ets.delete(tid)
    end
  end

  describe "lpush/4" do
    test "prepends values to a new list", %{write_store: write_store, read_store: read_store} do
      Lists.lpush(write_store, 0, "mylist", ["a", "b", "c"])
      assert ["c", "b", "a"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "prepends values to an existing list", %{write_store: write_store, read_store: read_store} do
      Lists.lpush(write_store, 0, "mylist", ["a"])
      Lists.lpush(write_store, 0, "mylist", ["b", "c"])
      assert ["c", "b", "a"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "handles single value", %{write_store: write_store, read_store: read_store} do
      Lists.lpush(write_store, 0, "mylist", ["x"])
      assert ["x"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end
  end

  describe "rpush/4" do
    test "appends values to a new list", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      assert ["a", "b", "c"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "appends values to an existing list", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a"])
      Lists.rpush(write_store, 0, "mylist", ["b", "c"])
      assert ["a", "b", "c"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "combines with lpush correctly", %{write_store: write_store, read_store: read_store} do
      Lists.lpush(write_store, 0, "mylist", ["a", "b"])
      Lists.rpush(write_store, 0, "mylist", ["x", "y"])
      assert ["b", "a", "x", "y"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end
  end

  describe "lpushx/4" do
    test "does not create new list if key doesn't exist", %{write_store: write_store, read_store: read_store} do
      Lists.lpushx(write_store, 0, "mylist", ["a", "b"])
      assert [] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "prepends to existing list", %{write_store: write_store, read_store: read_store} do
      Lists.lpush(write_store, 0, "mylist", ["a"])
      Lists.lpushx(write_store, 0, "mylist", ["b", "c"])
      assert ["c", "b", "a"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end
  end

  describe "rpushx/4" do
    test "does not create new list if key doesn't exist", %{write_store: write_store, read_store: read_store} do
      Lists.rpushx(write_store, 0, "mylist", ["a", "b"])
      assert [] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "appends to existing list", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a"])
      Lists.rpushx(write_store, 0, "mylist", ["b", "c"])
      assert ["a", "b", "c"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end
  end

  describe "lpop/3" do
    test "removes first element", %{write_store: write_store, read_store: read_store} do
      Lists.lpush(write_store, 0, "mylist", ["a", "b", "c"])
      Lists.lpop(write_store, 0, "mylist")
      assert ["b", "a"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "deletes list when last element is removed", %{write_store: write_store, read_store: read_store} do
      Lists.lpush(write_store, 0, "mylist", ["a"])
      Lists.lpop(write_store, 0, "mylist")
      assert [] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "does nothing on non-existent list", %{write_store: write_store, read_store: read_store} do
      Lists.lpop(write_store, 0, "nonexistent")
      assert [] = Read.Lists.lrange(read_store, 0, "nonexistent", 0, -1)
    end
  end

  describe "rpop/3" do
    test "removes last element", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      Lists.rpop(write_store, 0, "mylist")
      assert ["a", "b"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "deletes list when last element is removed", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a"])
      Lists.rpop(write_store, 0, "mylist")
      assert [] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "does nothing on non-existent list", %{write_store: write_store, read_store: read_store} do
      Lists.rpop(write_store, 0, "nonexistent")
      assert [] = Read.Lists.lrange(read_store, 0, "nonexistent", 0, -1)
    end
  end

  describe "lrem/5" do
    test "removes count occurrences from head with positive count", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "a", "c", "a"])
      Lists.lrem(write_store, 0, "mylist", 2, "a")
      assert ["b", "c", "a"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "removes count occurrences from tail with negative count", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "a", "c", "a"])
      Lists.lrem(write_store, 0, "mylist", -2, "a")
      assert ["a", "b", "c"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "removes all occurrences with count 0", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "a", "c", "a"])
      Lists.lrem(write_store, 0, "mylist", 0, "a")
      assert ["b", "c"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "deletes list when all elements are removed", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "a", "a"])
      Lists.lrem(write_store, 0, "mylist", 0, "a")
      assert [] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "does nothing when element not found", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      Lists.lrem(write_store, 0, "mylist", 2, "x")
      assert ["a", "b", "c"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end
  end

  describe "ltrim/5" do
    test "trims list to specified range", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c", "d", "e"])
      Lists.ltrim(write_store, 0, "mylist", 1, 3)
      assert ["b", "c", "d"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "handles negative indices", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c", "d", "e"])
      Lists.ltrim(write_store, 0, "mylist", 0, -2)
      assert ["a", "b", "c", "d"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "deletes list when range is empty", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      Lists.ltrim(write_store, 0, "mylist", 5, 10)
      assert [] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "handles range larger than list", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      Lists.ltrim(write_store, 0, "mylist", 0, 99)
      assert ["a", "b", "c"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end
  end

  describe "lset/5" do
    test "sets element at positive index", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      Lists.lset(write_store, 0, "mylist", 1, "x")
      assert ["a", "x", "c"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "sets element at negative index", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      Lists.lset(write_store, 0, "mylist", -1, "x")
      assert ["a", "b", "x"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "does nothing when index out of bounds", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      Lists.lset(write_store, 0, "mylist", 10, "x")
      assert ["a", "b", "c"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "does nothing on non-existent list", %{write_store: write_store, read_store: read_store} do
      Lists.lset(write_store, 0, "nonexistent", 0, "x")
      assert [] = Read.Lists.lrange(read_store, 0, "nonexistent", 0, -1)
    end
  end

  describe "linsert/6" do
    test "inserts before pivot", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      Lists.linsert(write_store, 0, "mylist", :before, "b", "x")
      assert ["a", "x", "b", "c"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "inserts after pivot", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      Lists.linsert(write_store, 0, "mylist", :after, "b", "x")
      assert ["a", "b", "x", "c"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "inserts at first occurrence of pivot", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c", "b"])
      Lists.linsert(write_store, 0, "mylist", :before, "b", "x")
      assert ["a", "x", "b", "c", "b"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "does nothing when pivot not found", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      Lists.linsert(write_store, 0, "mylist", :before, "x", "new")
      assert ["a", "b", "c"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "does nothing on non-existent list", %{write_store: write_store, read_store: read_store} do
      Lists.linsert(write_store, 0, "nonexistent", :before, "x", "new")
      assert [] = Read.Lists.lrange(read_store, 0, "nonexistent", 0, -1)
    end
  end

  describe "rpoplpush/4" do
    test "moves element from source to dest", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "source", ["a", "b", "c"])
      Lists.rpush(write_store, 0, "dest", ["x", "y"])
      Lists.rpoplpush(write_store, 0, "source", "dest")
      assert ["a", "b"] = Read.Lists.lrange(read_store, 0, "source", 0, -1)
      assert ["c", "x", "y"] = Read.Lists.lrange(read_store, 0, "dest", 0, -1)
    end

    test "creates dest list if it doesn't exist", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "source", ["a", "b", "c"])
      Lists.rpoplpush(write_store, 0, "source", "dest")
      assert ["a", "b"] = Read.Lists.lrange(read_store, 0, "source", 0, -1)
      assert ["c"] = Read.Lists.lrange(read_store, 0, "dest", 0, -1)
    end

    test "deletes source when it becomes empty", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "source", ["a"])
      Lists.rpoplpush(write_store, 0, "source", "dest")
      assert [] = Read.Lists.lrange(read_store, 0, "source", 0, -1)
      assert ["a"] = Read.Lists.lrange(read_store, 0, "dest", 0, -1)
    end

    test "works with same source and dest (rotation)", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      Lists.rpoplpush(write_store, 0, "mylist", "mylist")
      assert ["c", "a", "b"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "does nothing on non-existent source", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "dest", ["x"])
      Lists.rpoplpush(write_store, 0, "nonexistent", "dest")
      assert ["x"] = Read.Lists.lrange(read_store, 0, "dest", 0, -1)
    end
  end

  describe "lrange/5" do
    test "returns full list with 0 to -1", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c", "d", "e"])
      assert ["a", "b", "c", "d", "e"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "returns partial range", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c", "d", "e"])
      assert ["b", "c", "d"] = Read.Lists.lrange(read_store, 0, "mylist", 1, 3)
    end

    test "handles negative start index", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c", "d", "e"])
      assert ["d", "e"] = Read.Lists.lrange(read_store, 0, "mylist", -2, -1)
    end

    test "handles negative stop index", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c", "d", "e"])
      assert ["a", "b", "c", "d"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -2)
    end

    test "handles both negative indices", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c", "d", "e"])
      assert ["c", "d"] = Read.Lists.lrange(read_store, 0, "mylist", -3, -2)
    end

    test "returns empty list when range is invalid", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      assert [] = Read.Lists.lrange(read_store, 0, "mylist", 5, 10)
    end

    test "returns empty list when start > stop", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      assert [] = Read.Lists.lrange(read_store, 0, "mylist", 2, 1)
    end

    test "returns empty list for non-existent key", %{read_store: read_store} do
      assert [] = Read.Lists.lrange(read_store, 0, "nonexistent", 0, -1)
    end

    test "handles range larger than list", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      assert ["a", "b", "c"] = Read.Lists.lrange(read_store, 0, "mylist", 0, 99)
    end
  end

  describe "llen/3" do
    test "returns length of list", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      assert 3 = Read.Lists.llen(read_store, 0, "mylist")
    end

    test "returns 0 for non-existent list", %{read_store: read_store} do
      assert 0 = Read.Lists.llen(read_store, 0, "nonexistent")
    end

    test "returns 0 after list is deleted", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a"])
      Lists.lpop(write_store, 0, "mylist")
      assert 0 = Read.Lists.llen(read_store, 0, "mylist")
    end
  end

  describe "del/3" do
    test "deletes an existing list", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      Common.del(write_store.tid, 0, "mylist")
      assert [] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "does nothing when key doesn't exist", %{write_store: write_store, read_store: read_store} do
      Common.del(write_store.tid, 0, "nonexistent")
      assert [] = Read.Lists.lrange(read_store, 0, "nonexistent", 0, -1)
    end

    test "deleted list cannot be accessed with lpushx", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b"])
      Common.del(write_store.tid, 0, "mylist")

      # lpushx should not create new list
      Lists.lpushx(write_store, 0, "mylist", ["x"])
      assert [] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end

    test "can create new list after deletion with lpush", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b"])
      Common.del(write_store.tid, 0, "mylist")

      # lpush should create new list
      Lists.lpush(write_store, 0, "mylist", ["x", "y"])
      assert ["y", "x"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
    end
  end

  describe "decode_fun callback" do
    test "decodes values when pushing" do
      tid = :ets.new(:test, [:ordered_set, :public])
      decode_fun = fn key, val -> {:decoded, key, val} end
      write_store = Lists.new(tid, decode_fun)
    read_store = Read.Lists.new(tid)

      Lists.lpush(write_store, 0, "mylist", ["a", "b"])

      assert [{:decoded, "mylist", "b"}, {:decoded, "mylist", "a"}] =
               Read.Lists.lrange(read_store, 0, "mylist", 0, -1)

      :ets.delete(tid)
    end

    test "decodes values in lrem operation" do
      tid = :ets.new(:test, [:ordered_set, :public])
      decode_fun = fn _key, val -> String.upcase(val) end
      write_store = Lists.new(tid, decode_fun)
    read_store = Read.Lists.new(tid)

      Lists.rpush(write_store, 0, "mylist", ["a", "b", "a"])
      Lists.lrem(write_store, 0, "mylist", 1, "a")
      assert ["B", "A"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)

      :ets.delete(tid)
    end

    test "decodes values in linsert operation" do
      tid = :ets.new(:test, [:ordered_set, :public])
      decode_fun = fn _key, val -> String.upcase(val) end
      write_store = Lists.new(tid, decode_fun)
    read_store = Read.Lists.new(tid)

      Lists.rpush(write_store, 0, "mylist", ["a", "b", "c"])
      Lists.linsert(write_store, 0, "mylist", :before, "b", "x")
      assert ["A", "X", "B", "C"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)

      :ets.delete(tid)
    end

    test "works with rpoplpush" do
      tid = :ets.new(:test, [:ordered_set, :public])
      decode_fun = fn _key, val -> String.upcase(val) end
      write_store = Lists.new(tid, decode_fun)
    read_store = Read.Lists.new(tid)

      Lists.rpush(write_store, 0, "source", ["a", "b"])
      Lists.rpush(write_store, 0, "dest", ["x"])
      Lists.rpoplpush(write_store, 0, "source", "dest")

      assert ["A"] = Read.Lists.lrange(read_store, 0, "source", 0, -1)
      assert ["B", "X"] = Read.Lists.lrange(read_store, 0, "dest", 0, -1)

      :ets.delete(tid)
    end
  end

  describe "concurrent keys" do
    test "handles multiple keys independently", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "list1", ["a", "b"])
      Lists.rpush(write_store, 0, "list2", ["x", "y"])
      Lists.rpush(write_store, 0, "list3", ["1", "2"])

      assert ["a", "b"] = Read.Lists.lrange(read_store, 0, "list1", 0, -1)
      assert ["x", "y"] = Read.Lists.lrange(read_store, 0, "list2", 0, -1)
      assert ["1", "2"] = Read.Lists.lrange(read_store, 0, "list3", 0, -1)
    end

    test "handles multiple databases independently", %{write_store: write_store, read_store: read_store} do
      Lists.rpush(write_store, 0, "mylist", ["a", "b"])
      Lists.rpush(write_store, 1, "mylist", ["x", "y"])

      assert ["a", "b"] = Read.Lists.lrange(read_store, 0, "mylist", 0, -1)
      assert ["x", "y"] = Read.Lists.lrange(read_store, 1, "mylist", 0, -1)
    end
  end
end
