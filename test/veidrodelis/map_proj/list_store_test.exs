defmodule Vdr.MapProj.ListStoreTest do
  use ExUnit.Case, async: true

  alias Vdr.MapProj.{Lists, Common}

  setup do
    config = Lists.new(fn _key, val -> val end)
    store = %{}

    {:ok, config: config, store: store}
  end

  describe "new/1" do
    test "creates a new list config with decode function" do
      decode_fun = fn _key, val -> {:decoded, val} end
      config = Lists.new(decode_fun)

      assert %Vdr.MapProj.Lists{decode_fun: ^decode_fun} = config
    end
  end

  describe "lpush/5" do
    test "prepends values to a new list", %{config: config, store: store} do
      store = Lists.lpush(store, config, 0, "mylist", ["a", "b", "c"])
      assert ["c", "b", "a"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "prepends values to an existing list", %{config: config, store: store} do
      store = Lists.lpush(store, config, 0, "mylist", ["a"])
      store = Lists.lpush(store, config, 0, "mylist", ["b", "c"])
      assert ["c", "b", "a"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "handles single value", %{config: config, store: store} do
      store = Lists.lpush(store, config, 0, "mylist", ["x"])
      assert ["x"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end
  end

  describe "rpush/5" do
    test "appends values to a new list", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      assert ["a", "b", "c"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "appends values to an existing list", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a"])
      store = Lists.rpush(store, config, 0, "mylist", ["b", "c"])
      assert ["a", "b", "c"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "combines with lpush correctly", %{config: config, store: store} do
      store = Lists.lpush(store, config, 0, "mylist", ["a", "b"])
      store = Lists.rpush(store, config, 0, "mylist", ["x", "y"])
      assert ["b", "a", "x", "y"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end
  end

  describe "lpushx/5" do
    test "does not create new list if key doesn't exist", %{config: config, store: store} do
      store = Lists.lpushx(store, config, 0, "mylist", ["a", "b"])
      assert [] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "prepends to existing list", %{config: config, store: store} do
      store = Lists.lpush(store, config, 0, "mylist", ["a"])
      store = Lists.lpushx(store, config, 0, "mylist", ["b", "c"])
      assert ["c", "b", "a"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end
  end

  describe "rpushx/5" do
    test "does not create new list if key doesn't exist", %{config: config, store: store} do
      store = Lists.rpushx(store, config, 0, "mylist", ["a", "b"])
      assert [] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "appends to existing list", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a"])
      store = Lists.rpushx(store, config, 0, "mylist", ["b", "c"])
      assert ["a", "b", "c"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end
  end

  describe "lpop/3" do
    test "removes first element", %{config: config, store: store} do
      store = Lists.lpush(store, config, 0, "mylist", ["a", "b", "c"])
      store = Lists.lpop(store, 0, "mylist")
      assert ["b", "a"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "deletes list when last element is removed", %{config: config, store: store} do
      store = Lists.lpush(store, config, 0, "mylist", ["a"])
      store = Lists.lpop(store, 0, "mylist")
      assert [] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "does nothing on non-existent list", %{store: store} do
      store = Lists.lpop(store, 0, "nonexistent")
      assert [] = Lists.lrange(store, 0, "nonexistent", 0, -1)
    end
  end

  describe "rpop/3" do
    test "removes last element", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      store = Lists.rpop(store, 0, "mylist")
      assert ["a", "b"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "deletes list when last element is removed", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a"])
      store = Lists.rpop(store, 0, "mylist")
      assert [] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "does nothing on non-existent list", %{store: store} do
      store = Lists.rpop(store, 0, "nonexistent")
      assert [] = Lists.lrange(store, 0, "nonexistent", 0, -1)
    end
  end

  describe "lrem/6" do
    test "removes count occurrences from head with positive count", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "a", "c", "a"])
      store = Lists.lrem(store, config, 0, "mylist", 2, "a")
      assert ["b", "c", "a"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "removes count occurrences from tail with negative count", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "a", "c", "a"])
      store = Lists.lrem(store, config, 0, "mylist", -2, "a")
      assert ["a", "b", "c"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "removes all occurrences with count 0", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "a", "c", "a"])
      store = Lists.lrem(store, config, 0, "mylist", 0, "a")
      assert ["b", "c"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "deletes list when all elements are removed", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "a", "a"])
      store = Lists.lrem(store, config, 0, "mylist", 0, "a")
      assert [] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "does nothing when element not found", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      store = Lists.lrem(store, config, 0, "mylist", 2, "x")
      assert ["a", "b", "c"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end
  end

  describe "ltrim/5" do
    test "trims list to specified range", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c", "d", "e"])
      store = Lists.ltrim(store, 0, "mylist", 1, 3)
      assert ["b", "c", "d"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "handles negative indices", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c", "d", "e"])
      store = Lists.ltrim(store, 0, "mylist", 0, -2)
      assert ["a", "b", "c", "d"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "deletes list when range is empty", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      store = Lists.ltrim(store, 0, "mylist", 5, 10)
      assert [] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "handles range larger than list", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      store = Lists.ltrim(store, 0, "mylist", 0, 99)
      assert ["a", "b", "c"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end
  end

  describe "lset/6" do
    test "sets element at positive index", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      store = Lists.lset(store, config, 0, "mylist", 1, "x")
      assert ["a", "x", "c"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "sets element at negative index", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      store = Lists.lset(store, config, 0, "mylist", -1, "x")
      assert ["a", "b", "x"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "does nothing when index out of bounds", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      store = Lists.lset(store, config, 0, "mylist", 10, "x")
      assert ["a", "b", "c"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "does nothing on non-existent list", %{config: config, store: store} do
      store = Lists.lset(store, config, 0, "nonexistent", 0, "x")
      assert [] = Lists.lrange(store, 0, "nonexistent", 0, -1)
    end
  end

  describe "linsert/7" do
    test "inserts before pivot", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      store = Lists.linsert(store, config, 0, "mylist", :before, "b", "x")
      assert ["a", "x", "b", "c"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "inserts after pivot", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      store = Lists.linsert(store, config, 0, "mylist", :after, "b", "x")
      assert ["a", "b", "x", "c"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "inserts at first occurrence of pivot", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c", "b"])
      store = Lists.linsert(store, config, 0, "mylist", :before, "b", "x")
      assert ["a", "x", "b", "c", "b"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "does nothing when pivot not found", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      store = Lists.linsert(store, config, 0, "mylist", :before, "x", "new")
      assert ["a", "b", "c"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "does nothing on non-existent list", %{config: config, store: store} do
      store = Lists.linsert(store, config, 0, "nonexistent", :before, "x", "new")
      assert [] = Lists.lrange(store, 0, "nonexistent", 0, -1)
    end
  end

  describe "rpoplpush/4" do
    test "moves element from source to dest", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "source", ["a", "b", "c"])
      store = Lists.rpush(store, config, 0, "dest", ["x", "y"])
      store = Lists.rpoplpush(store, 0, "source", "dest")
      assert ["a", "b"] = Lists.lrange(store, 0, "source", 0, -1)
      assert ["c", "x", "y"] = Lists.lrange(store, 0, "dest", 0, -1)
    end

    test "creates dest list if it doesn't exist", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "source", ["a", "b", "c"])
      store = Lists.rpoplpush(store, 0, "source", "dest")
      assert ["a", "b"] = Lists.lrange(store, 0, "source", 0, -1)
      assert ["c"] = Lists.lrange(store, 0, "dest", 0, -1)
    end

    test "deletes source when it becomes empty", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "source", ["a"])
      store = Lists.rpoplpush(store, 0, "source", "dest")
      assert [] = Lists.lrange(store, 0, "source", 0, -1)
      assert ["a"] = Lists.lrange(store, 0, "dest", 0, -1)
    end

    test "works with same source and dest (rotation)", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      store = Lists.rpoplpush(store, 0, "mylist", "mylist")
      assert ["c", "a", "b"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "does nothing on non-existent source", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "dest", ["x"])
      store = Lists.rpoplpush(store, 0, "nonexistent", "dest")
      assert ["x"] = Lists.lrange(store, 0, "dest", 0, -1)
    end
  end

  describe "lrange/5" do
    test "returns full list with 0 to -1", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c", "d", "e"])
      assert ["a", "b", "c", "d", "e"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "returns partial range", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c", "d", "e"])
      assert ["b", "c", "d"] = Lists.lrange(store, 0, "mylist", 1, 3)
    end

    test "handles negative start index", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c", "d", "e"])
      assert ["d", "e"] = Lists.lrange(store, 0, "mylist", -2, -1)
    end

    test "handles negative stop index", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c", "d", "e"])
      assert ["a", "b", "c", "d"] = Lists.lrange(store, 0, "mylist", 0, -2)
    end

    test "handles both negative indices", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c", "d", "e"])
      assert ["c", "d"] = Lists.lrange(store, 0, "mylist", -3, -2)
    end

    test "returns empty list when range is invalid", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      assert [] = Lists.lrange(store, 0, "mylist", 5, 10)
    end

    test "returns empty list when start > stop", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      assert [] = Lists.lrange(store, 0, "mylist", 2, 1)
    end

    test "returns empty list for non-existent key", %{store: store} do
      assert [] = Lists.lrange(store, 0, "nonexistent", 0, -1)
    end

    test "handles range larger than list", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      assert ["a", "b", "c"] = Lists.lrange(store, 0, "mylist", 0, 99)
    end
  end

  describe "llen/3" do
    test "returns length of list", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      assert 3 = Lists.llen(store, 0, "mylist")
    end

    test "returns 0 for non-existent list", %{store: store} do
      assert 0 = Lists.llen(store, 0, "nonexistent")
    end

    test "returns 0 after list is deleted", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a"])
      store = Lists.lpop(store, 0, "mylist")
      assert 0 = Lists.llen(store, 0, "mylist")
    end
  end

  describe "del/3" do
    test "deletes an existing list", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      store = Common.del(store, 0, "mylist")
      assert [] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "does nothing when key doesn't exist", %{store: store} do
      store = Common.del(store, 0, "nonexistent")
      assert [] = Lists.lrange(store, 0, "nonexistent", 0, -1)
    end

    test "deleted list cannot be accessed with lpushx", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b"])
      store = Common.del(store, 0, "mylist")

      # lpushx should not create new list
      store = Lists.lpushx(store, config, 0, "mylist", ["x"])
      assert [] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "can create new list after deletion with lpush", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b"])
      store = Common.del(store, 0, "mylist")

      # lpush should create new list
      store = Lists.lpush(store, config, 0, "mylist", ["x", "y"])
      assert ["y", "x"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end
  end

  describe "decode_fun callback" do
    test "decodes values when pushing" do
      config = Lists.new(fn key, val -> {:decoded, key, val} end)
      store = %{}

      store = Lists.lpush(store, config, 0, "mylist", ["a", "b"])

      assert [{:decoded, "mylist", "b"}, {:decoded, "mylist", "a"}] =
               Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "decodes values in lrem operation" do
      config = Lists.new(fn _key, val -> String.upcase(val) end)
      store = %{}

      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "a"])
      store = Lists.lrem(store, config, 0, "mylist", 1, "a")
      assert ["B", "A"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "decodes values in linsert operation" do
      config = Lists.new(fn _key, val -> String.upcase(val) end)
      store = %{}

      store = Lists.rpush(store, config, 0, "mylist", ["a", "b", "c"])
      store = Lists.linsert(store, config, 0, "mylist", :before, "b", "x")
      assert ["A", "X", "B", "C"] = Lists.lrange(store, 0, "mylist", 0, -1)
    end

    test "works with rpoplpush" do
      config = Lists.new(fn _key, val -> String.upcase(val) end)
      store = %{}

      store = Lists.rpush(store, config, 0, "source", ["a", "b"])
      store = Lists.rpush(store, config, 0, "dest", ["x"])
      store = Lists.rpoplpush(store, 0, "source", "dest")

      assert ["A"] = Lists.lrange(store, 0, "source", 0, -1)
      assert ["B", "X"] = Lists.lrange(store, 0, "dest", 0, -1)
    end
  end

  describe "concurrent keys" do
    test "handles multiple keys independently", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "list1", ["a", "b"])
      store = Lists.rpush(store, config, 0, "list2", ["x", "y"])
      store = Lists.rpush(store, config, 0, "list3", ["1", "2"])

      assert ["a", "b"] = Lists.lrange(store, 0, "list1", 0, -1)
      assert ["x", "y"] = Lists.lrange(store, 0, "list2", 0, -1)
      assert ["1", "2"] = Lists.lrange(store, 0, "list3", 0, -1)
    end

    test "handles multiple databases independently", %{config: config, store: store} do
      store = Lists.rpush(store, config, 0, "mylist", ["a", "b"])
      store = Lists.rpush(store, config, 1, "mylist", ["x", "y"])

      assert ["a", "b"] = Lists.lrange(store, 0, "mylist", 0, -1)
      assert ["x", "y"] = Lists.lrange(store, 1, "mylist", 0, -1)
    end
  end
end
