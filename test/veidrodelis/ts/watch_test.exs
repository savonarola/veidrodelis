defmodule Vdr.TS.WatchTest do
  use ExUnit.Case, async: true

  alias Vdr.TS.Watch

  describe "create/0" do
    test "creates an empty watch storage" do
      watch = Watch.create()
      assert %Watch{} = watch
      assert [] = Watch.lookup(watch, "any_key")
    end
  end

  describe "add/4" do
    test "adds a watch entry" do
      watch = Watch.create()
      pid = self()

      {:ok, watch} = Watch.add(watch, pid, "key1", :ref1)

      assert [{:ref1, ^pid}] = Watch.lookup(watch, "key1")
    end

    test "adds multiple watches for the same pid" do
      watch = Watch.create()
      pid = self()

      {:ok, watch} = Watch.add(watch, pid, "key1", :ref1)
      {:ok, watch} = Watch.add(watch, pid, "key2", :ref2)

      assert [{:ref1, ^pid}] = Watch.lookup(watch, "key1")
      assert [{:ref2, ^pid}] = Watch.lookup(watch, "key2")
    end

    test "allows the same key for different pids" do
      watch = Watch.create()
      pid1 = self()
      pid2 = spawn(fn -> :ok end)

      {:ok, watch} = Watch.add(watch, pid1, "key1", :ref1)
      {:ok, watch} = Watch.add(watch, pid2, "key1", :ref2)

      results = Watch.lookup(watch, "key1")
      assert length(results) == 2
      assert {:ref1, pid1} in results
      assert {:ref2, pid2} in results
    end

    test "returns error if key already registered for the same pid" do
      watch = Watch.create()
      pid = self()

      {:ok, watch} = Watch.add(watch, pid, "key1", :ref1)
      {:error, :already_registered} = Watch.add(watch, pid, "key1", :ref2)

      # Original watch is still valid
      assert [{:ref1, ^pid}] = Watch.lookup(watch, "key1")
    end
  end

  describe "delete/3" do
    test "deletes a single watch entry" do
      watch = Watch.create()
      pid = self()

      {:ok, watch} = Watch.add(watch, pid, "key1", :ref1)
      {:ok, watch} = Watch.add(watch, pid, "key2", :ref2)

      {:ok, watch} = Watch.delete(watch, pid, "key1")

      assert [] = Watch.lookup(watch, "key1")
      assert [{:ref2, ^pid}] = Watch.lookup(watch, "key2")
    end

    test "removes watch completely when last watcher is deleted" do
      watch = Watch.create()
      pid = self()

      {:ok, watch} = Watch.add(watch, pid, "key1", :ref1)
      {:ok, watch} = Watch.delete(watch, pid, "key1")

      assert [] = Watch.lookup(watch, "key1")
    end

    test "only deletes for the specified pid" do
      watch = Watch.create()
      pid1 = self()
      pid2 = spawn(fn -> :ok end)

      {:ok, watch} = Watch.add(watch, pid1, "key1", :ref1)
      {:ok, watch} = Watch.add(watch, pid2, "key1", :ref2)

      {:ok, watch} = Watch.delete(watch, pid1, "key1")

      assert [{:ref2, ^pid2}] = Watch.lookup(watch, "key1")
    end

    test "returns error if key not found for pid" do
      watch = Watch.create()
      pid = self()

      {:error, :not_found} = Watch.delete(watch, pid, "key1")
    end

    test "returns error if pid has the key but different key requested" do
      watch = Watch.create()
      pid = self()

      {:ok, watch} = Watch.add(watch, pid, "key1", :ref1)

      {:error, :not_found} = Watch.delete(watch, pid, "key2")

      # Original watch is still there
      assert [{:ref1, ^pid}] = Watch.lookup(watch, "key1")
    end

    test "returns error if different pid tries to delete" do
      watch = Watch.create()
      pid1 = self()
      pid2 = spawn(fn -> :ok end)

      {:ok, watch} = Watch.add(watch, pid1, "key1", :ref1)

      {:error, :not_found} = Watch.delete(watch, pid2, "key1")

      # Original watch is still there
      assert [{:ref1, ^pid1}] = Watch.lookup(watch, "key1")
    end
  end

  describe "delete_all/2" do
    test "deletes all watches for a pid" do
      watch = Watch.create()
      pid = self()

      {:ok, watch} = Watch.add(watch, pid, "key1", :ref1)
      {:ok, watch} = Watch.add(watch, pid, "key2", :ref2)
      {:ok, watch} = Watch.add(watch, pid, "key3", :ref3)

      watch = Watch.delete_all(watch, pid)

      assert [] = Watch.lookup(watch, "key1")
      assert [] = Watch.lookup(watch, "key2")
      assert [] = Watch.lookup(watch, "key3")
    end

    test "only deletes watches for the specified pid" do
      watch = Watch.create()
      pid1 = self()
      pid2 = spawn(fn -> :ok end)

      {:ok, watch} = Watch.add(watch, pid1, "key1", :ref1)
      {:ok, watch} = Watch.add(watch, pid1, "key2", :ref2)
      {:ok, watch} = Watch.add(watch, pid2, "key3", :ref3)

      watch = Watch.delete_all(watch, pid1)

      assert [] = Watch.lookup(watch, "key1")
      assert [] = Watch.lookup(watch, "key2")
      assert [{:ref3, ^pid2}] = Watch.lookup(watch, "key3")
    end

    test "handles shared keys correctly" do
      watch = Watch.create()
      pid1 = self()
      pid2 = spawn(fn -> :ok end)

      {:ok, watch} = Watch.add(watch, pid1, "shared", :ref1)
      {:ok, watch} = Watch.add(watch, pid2, "shared", :ref2)

      watch = Watch.delete_all(watch, pid1)

      assert [{:ref2, ^pid2}] = Watch.lookup(watch, "shared")
    end

    test "succeeds even if pid has no watches" do
      watch = Watch.create()
      pid = self()

      watch = Watch.delete_all(watch, pid)

      assert [] = Watch.lookup(watch, "any_key")
    end
  end

  describe "lookup/2" do
    test "returns empty list for non-existent key" do
      watch = Watch.create()

      assert [] = Watch.lookup(watch, "nonexistent")
    end

    test "returns single watch for a key" do
      watch = Watch.create()
      pid = self()

      {:ok, watch} = Watch.add(watch, pid, "key1", :ref1)

      assert [{:ref1, ^pid}] = Watch.lookup(watch, "key1")
    end

    test "returns multiple watches for a key" do
      watch = Watch.create()
      pid1 = self()
      pid2 = spawn(fn -> :ok end)

      {:ok, watch} = Watch.add(watch, pid1, "key1", :ref1)
      {:ok, watch} = Watch.add(watch, pid2, "key1", :ref2)

      results = Watch.lookup(watch, "key1")
      assert length(results) == 2
      assert {:ref1, pid1} in results
      assert {:ref2, pid2} in results
    end

    test "returns empty list after all watches are deleted" do
      watch = Watch.create()
      pid = self()

      {:ok, watch} = Watch.add(watch, pid, "key1", :ref1)
      {:ok, watch} = Watch.delete(watch, pid, "key1")

      assert [] = Watch.lookup(watch, "key1")
    end
  end

  describe "integration scenarios" do
    test "complex scenario with multiple pids and keys" do
      watch = Watch.create()
      pid1 = self()
      pid2 = spawn(fn -> :ok end)
      pid3 = spawn(fn -> :ok end)

      # Add various watches
      {:ok, watch} = Watch.add(watch, pid1, "user:123", :ref1)
      {:ok, watch} = Watch.add(watch, pid1, "user:456", :ref2)
      {:ok, watch} = Watch.add(watch, pid2, "user:123", :ref3)
      {:ok, watch} = Watch.add(watch, pid3, "order:789", :ref4)

      # Verify lookups
      results = Watch.lookup(watch, "user:123")
      assert length(results) == 2
      assert {:ref1, pid1} in results
      assert {:ref3, pid2} in results

      # Delete single watch
      {:ok, watch} = Watch.delete(watch, pid1, "user:123")
      assert [{:ref3, ^pid2}] = Watch.lookup(watch, "user:123")

      # Delete all for pid1
      watch = Watch.delete_all(watch, pid1)
      assert [] = Watch.lookup(watch, "user:456")
      assert [{:ref3, ^pid2}] = Watch.lookup(watch, "user:123")
      assert [{:ref4, ^pid3}] = Watch.lookup(watch, "order:789")
    end

    test "handles ref types correctly" do
      watch = Watch.create()
      pid = self()

      # Test with various ref types
      {:ok, watch} = Watch.add(watch, pid, "key1", :atom_ref)
      {:ok, watch} = Watch.add(watch, pid, "key2", "string_ref")
      {:ok, watch} = Watch.add(watch, pid, "key3", 123)
      ref = make_ref()
      {:ok, watch} = Watch.add(watch, pid, "key4", ref)

      assert [{:atom_ref, ^pid}] = Watch.lookup(watch, "key1")
      assert [{"string_ref", ^pid}] = Watch.lookup(watch, "key2")
      assert [{123, ^pid}] = Watch.lookup(watch, "key3")
      assert [{^ref, ^pid}] = Watch.lookup(watch, "key4")
    end

    test "add, lookup, delete cycle" do
      watch = Watch.create()
      pid = self()

      # Start with empty
      assert [] = Watch.lookup(watch, "key1")

      # Add watch
      {:ok, watch} = Watch.add(watch, pid, "key1", :ref1)
      assert [{:ref1, ^pid}] = Watch.lookup(watch, "key1")

      # Try to add duplicate
      {:error, :already_registered} = Watch.add(watch, pid, "key1", :ref2)
      assert [{:ref1, ^pid}] = Watch.lookup(watch, "key1")

      # Delete watch
      {:ok, watch} = Watch.delete(watch, pid, "key1")
      assert [] = Watch.lookup(watch, "key1")

      # Try to delete again
      {:error, :not_found} = Watch.delete(watch, pid, "key1")
      assert [] = Watch.lookup(watch, "key1")

      # Add again after deletion
      {:ok, watch} = Watch.add(watch, pid, "key1", :ref3)
      assert [{:ref3, ^pid}] = Watch.lookup(watch, "key1")
    end
  end
end
