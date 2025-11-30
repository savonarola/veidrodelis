defmodule Veidrodelis.ListStoreTest do
  use ExUnit.Case, async: true

  alias Veidrodelis.ListStore

  setup do
    store = ListStore.new()
    {:ok, store: store}
  end

  describe "new/1" do
    test "creates a new GenServer and returns a struct" do
      store = ListStore.new()

      assert %ListStore{pid: pid} = store
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Clean up
      ListStore.destroy(store)
    end

    test "accepts GenServer options" do
      store = ListStore.new(name: :test_list_store)

      assert %ListStore{pid: pid} = store
      assert Process.alive?(pid)

      # Verify it's registered
      assert Process.whereis(:test_list_store) == pid

      # Clean up
      ListStore.destroy(store)
    end

    test "accepts decode_fun option" do
      decode_fun = fn _key, val -> {:decoded, val} end
      store = ListStore.new(decode_fun: decode_fun)

      assert %ListStore{pid: pid} = store
      assert Process.alive?(pid)

      # Test that decode function is used
      ListStore.lpush(store, 0, "mylist", ["test"])
      assert [{:decoded, "test"}] = ListStore.get_range(store, 0, "mylist", 0, -1)

      # Clean up
      ListStore.destroy(store)
    end

    test "defaults to identity function when decode_fun not provided" do
      store = ListStore.new()

      # Non-binary values should pass through unchanged
      ListStore.lpush(store, 0, "mylist", [123, "test", :atom])
      assert [:atom, "test", 123] = ListStore.get_range(store, 0, "mylist", 0, -1)

      # Clean up
      ListStore.destroy(store)
    end
  end

  describe "destroy/1" do
    test "stops the GenServer process" do
      store = ListStore.new()

      assert Process.alive?(store.pid)

      :ok = ListStore.destroy(store)

      # Give it a moment to stop
      Process.sleep(10)
      refute Process.alive?(store.pid)
    end

    test "returns :ok" do
      store = ListStore.new()
      assert :ok = ListStore.destroy(store)
    end
  end

  describe "lpush/4" do
    test "prepends values to a new list", %{store: store} do
      ListStore.lpush(store, 0, "mylist", ["a", "b", "c"])
      assert ["c", "b", "a"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "prepends values to an existing list", %{store: store} do
      ListStore.lpush(store, 0, "mylist", ["a"])
      ListStore.lpush(store, 0, "mylist", ["b", "c"])
      assert ["c", "b", "a"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "handles single value", %{store: store} do
      ListStore.lpush(store, 0, "mylist", ["x"])
      assert ["x"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end
  end

  describe "rpush/4" do
    test "appends values to a new list", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      assert ["a", "b", "c"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "appends values to an existing list", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a"])
      ListStore.rpush(store, 0, "mylist", ["b", "c"])
      assert ["a", "b", "c"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "combines with lpush correctly", %{store: store} do
      ListStore.lpush(store, 0, "mylist", ["a", "b"])
      ListStore.rpush(store, 0, "mylist", ["x", "y"])
      assert ["b", "a", "x", "y"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end
  end

  describe "lpushx/4" do
    test "does not create new list if key doesn't exist", %{store: store} do
      ListStore.lpushx(store, 0, "mylist", ["a", "b"])
      # Give it time to process
      Process.sleep(10)
      assert [] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "prepends to existing list", %{store: store} do
      ListStore.lpush(store, 0, "mylist", ["a"])
      ListStore.lpushx(store, 0, "mylist", ["b", "c"])
      Process.sleep(10)
      assert ["c", "b", "a"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end
  end

  describe "rpushx/4" do
    test "does not create new list if key doesn't exist", %{store: store} do
      ListStore.rpushx(store, 0, "mylist", ["a", "b"])
      Process.sleep(10)
      assert [] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "appends to existing list", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a"])
      ListStore.rpushx(store, 0, "mylist", ["b", "c"])
      Process.sleep(10)
      assert ["a", "b", "c"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end
  end

  describe "lpop/3" do
    test "removes first element", %{store: store} do
      ListStore.lpush(store, 0, "mylist", ["a", "b", "c"])
      ListStore.lpop(store, 0, "mylist")
      Process.sleep(10)
      assert ["b", "a"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "deletes list when last element is removed", %{store: store} do
      ListStore.lpush(store, 0, "mylist", ["a"])
      ListStore.lpop(store, 0, "mylist")
      Process.sleep(10)
      assert [] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "does nothing on non-existent list", %{store: store} do
      ListStore.lpop(store, 0, "nonexistent")
      Process.sleep(10)
      assert [] = ListStore.get_range(store, 0, "nonexistent", 0, -1)
    end
  end

  describe "rpop/3" do
    test "removes last element", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      ListStore.rpop(store, 0, "mylist")
      Process.sleep(10)
      assert ["a", "b"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "deletes list when last element is removed", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a"])
      ListStore.rpop(store, 0, "mylist")
      Process.sleep(10)
      assert [] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "does nothing on non-existent list", %{store: store} do
      ListStore.rpop(store, 0, "nonexistent")
      Process.sleep(10)
      assert [] = ListStore.get_range(store, 0, "nonexistent", 0, -1)
    end
  end

  describe "lrem/5" do
    test "removes count occurrences from head with positive count", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "a", "c", "a"])
      ListStore.lrem(store, 0, "mylist", 2, "a")
      Process.sleep(10)
      assert ["b", "c", "a"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "removes count occurrences from tail with negative count", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "a", "c", "a"])
      ListStore.lrem(store, 0, "mylist", -2, "a")
      Process.sleep(10)
      assert ["a", "b", "c"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "removes all occurrences with count 0", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "a", "c", "a"])
      ListStore.lrem(store, 0, "mylist", 0, "a")
      Process.sleep(10)
      assert ["b", "c"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "deletes list when all elements are removed", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "a", "a"])
      ListStore.lrem(store, 0, "mylist", 0, "a")
      Process.sleep(10)
      assert [] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "does nothing when element not found", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      ListStore.lrem(store, 0, "mylist", 2, "x")
      Process.sleep(10)
      assert ["a", "b", "c"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end
  end

  describe "ltrim/5" do
    test "trims list to specified range", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c", "d", "e"])
      ListStore.ltrim(store, 0, "mylist", 1, 3)
      Process.sleep(10)
      assert ["b", "c", "d"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "handles negative indices", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c", "d", "e"])
      ListStore.ltrim(store, 0, "mylist", 0, -2)
      Process.sleep(10)
      assert ["a", "b", "c", "d"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "deletes list when range is empty", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      ListStore.ltrim(store, 0, "mylist", 5, 10)
      Process.sleep(10)
      assert [] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "handles range larger than list", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      ListStore.ltrim(store, 0, "mylist", 0, 99)
      Process.sleep(10)
      assert ["a", "b", "c"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end
  end

  describe "lset/5" do
    test "sets element at positive index", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      ListStore.lset(store, 0, "mylist", 1, "x")
      Process.sleep(10)
      assert ["a", "x", "c"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "sets element at negative index", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      ListStore.lset(store, 0, "mylist", -1, "x")
      Process.sleep(10)
      assert ["a", "b", "x"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "does nothing when index out of bounds", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      ListStore.lset(store, 0, "mylist", 10, "x")
      Process.sleep(10)
      assert ["a", "b", "c"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "does nothing on non-existent list", %{store: store} do
      ListStore.lset(store, 0, "nonexistent", 0, "x")
      Process.sleep(10)
      assert [] = ListStore.get_range(store, 0, "nonexistent", 0, -1)
    end
  end

  describe "linsert/6" do
    test "inserts before pivot", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      ListStore.linsert(store, 0, "mylist", :before, "b", "x")
      Process.sleep(10)
      assert ["a", "x", "b", "c"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "inserts after pivot", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      ListStore.linsert(store, 0, "mylist", :after, "b", "x")
      Process.sleep(10)
      assert ["a", "b", "x", "c"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "inserts at first occurrence of pivot", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c", "b"])
      ListStore.linsert(store, 0, "mylist", :before, "b", "x")
      Process.sleep(10)
      assert ["a", "x", "b", "c", "b"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "does nothing when pivot not found", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      ListStore.linsert(store, 0, "mylist", :before, "x", "new")
      Process.sleep(10)
      assert ["a", "b", "c"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "does nothing on non-existent list", %{store: store} do
      ListStore.linsert(store, 0, "nonexistent", :before, "x", "new")
      Process.sleep(10)
      assert [] = ListStore.get_range(store, 0, "nonexistent", 0, -1)
    end
  end

  describe "rpoplpush/4" do
    test "moves element from source to dest", %{store: store} do
      ListStore.rpush(store, 0, "source", ["a", "b", "c"])
      ListStore.rpush(store, 0, "dest", ["x", "y"])
      ListStore.rpoplpush(store, 0, "source", "dest")
      Process.sleep(10)
      assert ["a", "b"] = ListStore.get_range(store, 0, "source", 0, -1)
      assert ["c", "x", "y"] = ListStore.get_range(store, 0, "dest", 0, -1)
    end

    test "creates dest list if it doesn't exist", %{store: store} do
      ListStore.rpush(store, 0, "source", ["a", "b", "c"])
      ListStore.rpoplpush(store, 0, "source", "dest")
      Process.sleep(10)
      assert ["a", "b"] = ListStore.get_range(store, 0, "source", 0, -1)
      assert ["c"] = ListStore.get_range(store, 0, "dest", 0, -1)
    end

    test "deletes source when it becomes empty", %{store: store} do
      ListStore.rpush(store, 0, "source", ["a"])
      ListStore.rpoplpush(store, 0, "source", "dest")
      Process.sleep(10)
      assert [] = ListStore.get_range(store, 0, "source", 0, -1)
      assert ["a"] = ListStore.get_range(store, 0, "dest", 0, -1)
    end

    test "works with same source and dest (rotation)", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      ListStore.rpoplpush(store, 0, "mylist", "mylist")
      Process.sleep(10)
      assert ["c", "a", "b"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "does nothing on non-existent source", %{store: store} do
      ListStore.rpush(store, 0, "dest", ["x"])
      ListStore.rpoplpush(store, 0, "nonexistent", "dest")
      Process.sleep(10)
      assert ["x"] = ListStore.get_range(store, 0, "dest", 0, -1)
    end
  end

  describe "get_range/5" do
    test "returns full list with 0 to -1", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c", "d", "e"])
      assert ["a", "b", "c", "d", "e"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "returns partial range", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c", "d", "e"])
      assert ["b", "c", "d"] = ListStore.get_range(store, 0, "mylist", 1, 3)
    end

    test "handles negative start index", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c", "d", "e"])
      assert ["d", "e"] = ListStore.get_range(store, 0, "mylist", -2, -1)
    end

    test "handles negative stop index", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c", "d", "e"])
      assert ["a", "b", "c", "d"] = ListStore.get_range(store, 0, "mylist", 0, -2)
    end

    test "handles both negative indices", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c", "d", "e"])
      assert ["c", "d"] = ListStore.get_range(store, 0, "mylist", -3, -2)
    end

    test "returns empty list when range is invalid", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      assert [] = ListStore.get_range(store, 0, "mylist", 5, 10)
    end

    test "returns empty list when start > stop", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      assert [] = ListStore.get_range(store, 0, "mylist", 2, 1)
    end

    test "returns empty list for non-existent key", %{store: store} do
      assert [] = ListStore.get_range(store, 0, "nonexistent", 0, -1)
    end

    test "handles range larger than list", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      assert ["a", "b", "c"] = ListStore.get_range(store, 0, "mylist", 0, 99)
    end
  end

  describe "empty list deletion" do
    test "list is deleted after lpop empties it", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a"])
      ListStore.lpop(store, 0, "mylist")
      Process.sleep(10)

      # Try to use lpushx which only works on existing keys
      ListStore.lpushx(store, 0, "mylist", ["x"])
      Process.sleep(10)
      assert [] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "list is deleted after rpop empties it", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a"])
      ListStore.rpop(store, 0, "mylist")
      Process.sleep(10)

      ListStore.rpushx(store, 0, "mylist", ["x"])
      Process.sleep(10)
      assert [] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "list is deleted after lrem removes all elements", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "a"])
      ListStore.lrem(store, 0, "mylist", 0, "a")
      Process.sleep(10)

      ListStore.lpushx(store, 0, "mylist", ["x"])
      Process.sleep(10)
      assert [] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "list is deleted after ltrim results in empty range", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b"])
      ListStore.ltrim(store, 0, "mylist", 5, 10)
      Process.sleep(10)

      ListStore.lpushx(store, 0, "mylist", ["x"])
      Process.sleep(10)
      assert [] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "list is deleted after rpoplpush empties it", %{store: store} do
      ListStore.rpush(store, 0, "source", ["a"])
      ListStore.rpoplpush(store, 0, "source", "dest")
      Process.sleep(10)

      ListStore.lpushx(store, 0, "source", ["x"])
      Process.sleep(10)
      assert [] = ListStore.get_range(store, 0, "source", 0, -1)
      assert ["a"] = ListStore.get_range(store, 0, "dest", 0, -1)
    end
  end

  describe "del/3" do
    test "deletes an existing list", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      ListStore.del(store, 0, "mylist")
      assert [] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "does nothing when key doesn't exist", %{store: store} do
      ListStore.del(store, 0, "nonexistent")
      assert [] = ListStore.get_range(store, 0, "nonexistent", 0, -1)
    end

    test "deleted list cannot be accessed with lpushx", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b"])
      ListStore.del(store, 0, "mylist")

      # lpushx should not create new list
      ListStore.lpushx(store, 0, "mylist", ["x"])
      assert [] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "deleted list cannot be accessed with rpushx", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b"])
      ListStore.del(store, 0, "mylist")

      # rpushx should not create new list
      ListStore.rpushx(store, 0, "mylist", ["x"])
      assert [] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "can create new list after deletion with lpush", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b"])
      ListStore.del(store, 0, "mylist")

      # lpush should create new list
      ListStore.lpush(store, 0, "mylist", ["x", "y"])
      assert ["y", "x"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end

    test "can create new list after deletion with rpush", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a", "b"])
      ListStore.del(store, 0, "mylist")

      # rpush should create new list
      ListStore.rpush(store, 0, "mylist", ["x", "y"])
      assert ["x", "y"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end
  end

  describe "concurrent operations" do
    test "handles multiple keys independently", %{store: store} do
      ListStore.rpush(store, 0, "list1", ["a", "b"])
      ListStore.rpush(store, 0, "list2", ["x", "y"])
      ListStore.rpush(store, 0, "list3", ["1", "2"])
      Process.sleep(10)

      assert ["a", "b"] = ListStore.get_range(store, 0, "list1", 0, -1)
      assert ["x", "y"] = ListStore.get_range(store, 0, "list2", 0, -1)
      assert ["1", "2"] = ListStore.get_range(store, 0, "list3", 0, -1)
    end

    test "handles rapid operations on same key", %{store: store} do
      ListStore.rpush(store, 0, "mylist", ["a"])
      ListStore.lpush(store, 0, "mylist", ["b"])
      ListStore.rpush(store, 0, "mylist", ["c"])
      ListStore.lpush(store, 0, "mylist", ["d"])
      Process.sleep(10)

      assert ["d", "b", "a", "c"] = ListStore.get_range(store, 0, "mylist", 0, -1)
    end
  end

  describe "decode_fun callback" do
    test "decodes binary values when pushing", %{store: _store} do
      decode_fun = fn key, val -> {:decoded, key, val} end
      store = ListStore.new(decode_fun: decode_fun)

      ListStore.lpush(store, 0, "mylist", ["a", "b"])

      assert [{:decoded, "mylist", "b"}, {:decoded, "mylist", "a"}] =
               ListStore.get_range(store, 0, "mylist", 0, -1)

      ListStore.destroy(store)
    end

    test "decodes binary values when appending", %{store: _store} do
      decode_fun = fn _key, val -> String.upcase(val) end
      store = ListStore.new(decode_fun: decode_fun)

      ListStore.rpush(store, 0, "mylist", ["hello", "world"])
      assert ["HELLO", "WORLD"] = ListStore.get_range(store, 0, "mylist", 0, -1)

      ListStore.destroy(store)
    end

    test "decodes binary values in lrem operation", %{store: _store} do
      decode_fun = fn _key, val -> String.upcase(val) end
      store = ListStore.new(decode_fun: decode_fun)

      ListStore.rpush(store, 0, "mylist", ["a", "b", "a"])
      ListStore.lrem(store, 0, "mylist", 1, "a")
      Process.sleep(10)
      assert ["B", "A"] = ListStore.get_range(store, 0, "mylist", 0, -1)

      ListStore.destroy(store)
    end

    test "decodes binary values in lset operation", %{store: _store} do
      decode_fun = fn _key, val -> String.upcase(val) end
      store = ListStore.new(decode_fun: decode_fun)

      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      ListStore.lset(store, 0, "mylist", 1, "x")
      Process.sleep(10)
      assert ["A", "X", "C"] = ListStore.get_range(store, 0, "mylist", 0, -1)

      ListStore.destroy(store)
    end

    test "decodes binary values in linsert operation", %{store: _store} do
      decode_fun = fn _key, val -> String.upcase(val) end
      store = ListStore.new(decode_fun: decode_fun)

      ListStore.rpush(store, 0, "mylist", ["a", "b", "c"])
      ListStore.linsert(store, 0, "mylist", :before, "b", "x")
      Process.sleep(10)
      assert ["A", "X", "B", "C"] = ListStore.get_range(store, 0, "mylist", 0, -1)

      ListStore.destroy(store)
    end

    test "passes non-binary values through unchanged", %{store: _store} do
      decode_fun = fn _key, val -> {:decoded, val} end
      store = ListStore.new(decode_fun: decode_fun)

      # Non-binary values should not be decoded
      ListStore.lpush(store, 0, "mylist", [123, :atom, "binary"])
      result = ListStore.get_range(store, 0, "mylist", 0, -1)
      # Binary "binary" should be decoded, non-binaries pass through
      assert Enum.member?(result, {:decoded, "binary"})
      assert Enum.member?(result, 123)
      assert Enum.member?(result, :atom)
      refute Enum.member?(result, "binary")

      ListStore.destroy(store)
    end

    test "decode function receives correct key", %{store: _store} do
      received_keys = Agent.start_link(fn -> [] end) |> elem(1)

      decode_fun = fn key, val ->
        Agent.update(received_keys, fn keys -> [key | keys] end)
        val
      end

      store = ListStore.new(decode_fun: decode_fun)

      ListStore.lpush(store, 0, "key1", ["a"])
      ListStore.rpush(store, 0, "key2", ["b"])
      Process.sleep(10)

      keys = Agent.get(received_keys, & &1)
      assert "key1" in keys
      assert "key2" in keys

      ListStore.destroy(store)
    end

    test "works with lpushx and rpushx", %{store: _store} do
      decode_fun = fn _key, val -> String.upcase(val) end
      store = ListStore.new(decode_fun: decode_fun)

      ListStore.rpush(store, 0, "mylist", ["a"])
      ListStore.lpushx(store, 0, "mylist", ["b"])
      ListStore.rpushx(store, 0, "mylist", ["c"])
      Process.sleep(10)

      assert ["B", "A", "C"] = ListStore.get_range(store, 0, "mylist", 0, -1)

      ListStore.destroy(store)
    end

    test "works with rpoplpush", %{store: _store} do
      decode_fun = fn _key, val -> String.upcase(val) end
      store = ListStore.new(decode_fun: decode_fun)

      ListStore.rpush(store, 0, "source", ["a", "b"])
      ListStore.rpush(store, 0, "dest", ["x"])
      ListStore.rpoplpush(store, 0, "source", "dest")
      Process.sleep(10)

      assert ["A"] = ListStore.get_range(store, 0, "source", 0, -1)
      assert ["B", "X"] = ListStore.get_range(store, 0, "dest", 0, -1)

      ListStore.destroy(store)
    end
  end
end
