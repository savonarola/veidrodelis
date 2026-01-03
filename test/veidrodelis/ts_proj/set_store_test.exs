defmodule Vdr.TSProj.SetStoreTest do
  use ExUnit.Case, async: true

  setup do
    storage = Vdr.TS.create()
    {:ok, storage: storage}
  end

  describe "sadd/4" do
    test "adds members to a set", %{storage: storage} do
      [:ok] = Vdr.TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c"]}}])

      {:ok, members} = Vdr.TS.smembers(storage, 0, "myset")
      assert Enum.sort(members) == ["a", "b", "c"]
    end

    test "adding duplicate members is idempotent", %{storage: storage} do
      [:ok] = Vdr.TS.tx(storage, [{0, {:sadd, "myset", ["a", "b"]}}])
      [:ok] = Vdr.TS.tx(storage, [{0, {:sadd, "myset", ["b", "c"]}}])

      {:ok, members} = Vdr.TS.smembers(storage, 0, "myset")
      assert Enum.sort(members) == ["a", "b", "c"]
    end

    test "supports multiple databases", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "myset", ["a", "b"]}}])
      Vdr.TS.tx(storage, [{1, {:sadd, "myset", ["x", "y"]}}])

      {:ok, members_db0} = Vdr.TS.smembers(storage, 0, "myset")
      {:ok, members_db1} = Vdr.TS.smembers(storage, 1, "myset")

      assert Enum.sort(members_db0) == ["a", "b"]
      assert Enum.sort(members_db1) == ["x", "y"]
    end

    test "adds empty list of members", %{storage: storage} do
      [:ok] = Vdr.TS.tx(storage, [{0, {:sadd, "myset", []}}])
      assert {:ok, []} = Vdr.TS.smembers(storage, 0, "myset")
    end

    test "returns error on type mismatch", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:set, "mystring", "value"}}])
      [{:error, :wrong_type}] = Vdr.TS.tx(storage, [{0, {:sadd, "mystring", ["a"]}}])
    end
  end

  describe "srem/4" do
    test "removes members from a set", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c", "d"]}}])
      [:ok] = Vdr.TS.tx(storage, [{0, {:srem, "myset", ["b", "d"]}}])

      {:ok, members} = Vdr.TS.smembers(storage, 0, "myset")
      assert Enum.sort(members) == ["a", "c"]
    end

    test "removing non-existent members is safe", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "myset", ["a", "b"]}}])
      [:ok] = Vdr.TS.tx(storage, [{0, {:srem, "myset", ["c", "d"]}}])

      {:ok, members} = Vdr.TS.smembers(storage, 0, "myset")
      assert Enum.sort(members) == ["a", "b"]
    end

    test "removes all members and deletes key", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c"]}}])
      [:ok] = Vdr.TS.tx(storage, [{0, {:srem, "myset", ["a", "b", "c"]}}])

      # Set should be gone
      assert {:ok, []} = Vdr.TS.smembers(storage, 0, "myset")
      assert {:ok, 0} = Vdr.TS.scard(storage, 0, "myset")
    end

    test "returns error on type mismatch", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:set, "mystring", "value"}}])
      [{:error, :wrong_type}] = Vdr.TS.tx(storage, [{0, {:srem, "mystring", ["a"]}}])
    end
  end

  describe "smove/5" do
    test "moves member from source to destination", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "set1", ["a", "b", "c"]}}])
      Vdr.TS.tx(storage, [{0, {:sadd, "set2", ["x", "y"]}}])

      [:ok] = Vdr.TS.tx(storage, [{0, {:smove, "set1", "set2", "b"}}])

      {:ok, set1_members} = Vdr.TS.smembers(storage, 0, "set1")
      {:ok, set2_members} = Vdr.TS.smembers(storage, 0, "set2")

      assert Enum.sort(set1_members) == ["a", "c"]
      assert Enum.sort(set2_members) == ["b", "x", "y"]
    end

    test "moves member and deletes source if it becomes empty", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "set1", ["a"]}}])
      Vdr.TS.tx(storage, [{0, {:sadd, "set2", ["x"]}}])

      [:ok] = Vdr.TS.tx(storage, [{0, {:smove, "set1", "set2", "a"}}])

      # Source should be deleted
      assert {:ok, []} = Vdr.TS.smembers(storage, 0, "set1")
      assert {:ok, 0} = Vdr.TS.scard(storage, 0, "set1")

      # Destination should have both members
      {:ok, set2_members} = Vdr.TS.smembers(storage, 0, "set2")
      assert Enum.sort(set2_members) == ["a", "x"]
    end

    test "succeeds even if member doesn't exist", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "set1", ["a", "b"]}}])
      Vdr.TS.tx(storage, [{0, {:sadd, "set2", ["x"]}}])

      [:ok] = Vdr.TS.tx(storage, [{0, {:smove, "set1", "set2", "z"}}])

      # Nothing should change
      assert {:ok, set1_members} = Vdr.TS.smembers(storage, 0, "set1")
      assert Enum.sort(set1_members) == ["a", "b"]
      assert {:ok, ["x"]} = Vdr.TS.smembers(storage, 0, "set2")
    end

    test "returns error on type mismatch", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:set, "mystring", "value"}}])
      Vdr.TS.tx(storage, [{0, {:sadd, "myset", ["a"]}}])

      [{:error, :wrong_type}] = Vdr.TS.tx(storage, [{0, {:smove, "mystring", "myset", "a"}}])
      [{:error, :wrong_type}] = Vdr.TS.tx(storage, [{0, {:smove, "myset", "mystring", "a"}}])
    end
  end

  describe "sunionstore/4" do
    test "stores union of multiple sets", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "set1", ["a", "b"]}}])
      Vdr.TS.tx(storage, [{0, {:sadd, "set2", ["b", "c"]}}])
      Vdr.TS.tx(storage, [{0, {:sadd, "set3", ["c", "d"]}}])

      [:ok] = Vdr.TS.tx(storage, [{0, {:sunionstore, "result", ["set1", "set2", "set3"]}}])

      {:ok, result_members} = Vdr.TS.smembers(storage, 0, "result")
      assert Enum.sort(result_members) == ["a", "b", "c", "d"]
    end

    test "handles non-existent source sets", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "set1", ["a", "b"]}}])

      [:ok] = Vdr.TS.tx(storage, [{0, {:sunionstore, "result", ["set1", "nonexistent"]}}])

      {:ok, result_members} = Vdr.TS.smembers(storage, 0, "result")
      assert Enum.sort(result_members) == ["a", "b"]
    end

    test "returns error on type mismatch", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:set, "mystring", "value"}}])
      Vdr.TS.tx(storage, [{0, {:sadd, "myset", ["a"]}}])

      [{:error, :wrong_type}] =
        Vdr.TS.tx(storage, [{0, {:sunionstore, "result", ["myset", "mystring"]}}])
    end
  end

  describe "sinterstore/4" do
    test "stores intersection of multiple sets", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "set1", ["a", "b", "c", "d"]}}])
      Vdr.TS.tx(storage, [{0, {:sadd, "set2", ["b", "c", "e", "f"]}}])
      Vdr.TS.tx(storage, [{0, {:sadd, "set3", ["c", "d", "g"]}}])

      [:ok] = Vdr.TS.tx(storage, [{0, {:sinterstore, "result", ["set1", "set2", "set3"]}}])

      {:ok, result_members} = Vdr.TS.smembers(storage, 0, "result")
      assert result_members == ["c"]
    end

    test "handles empty intersection", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "set1", ["a", "b"]}}])
      Vdr.TS.tx(storage, [{0, {:sadd, "set2", ["c", "d"]}}])

      [:ok] = Vdr.TS.tx(storage, [{0, {:sinterstore, "result", ["set1", "set2"]}}])

      assert {:ok, []} = Vdr.TS.smembers(storage, 0, "result")
    end

    test "returns error on type mismatch", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:set, "mystring", "value"}}])
      Vdr.TS.tx(storage, [{0, {:sadd, "myset", ["a"]}}])

      [{:error, :wrong_type}] =
        Vdr.TS.tx(storage, [{0, {:sinterstore, "result", ["myset", "mystring"]}}])
    end
  end

  describe "sdiffstore/4" do
    test "stores difference of sets", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "set1", ["a", "b", "c", "d", "e"]}}])
      Vdr.TS.tx(storage, [{0, {:sadd, "set2", ["b", "d"]}}])
      Vdr.TS.tx(storage, [{0, {:sadd, "set3", ["c"]}}])

      [:ok] = Vdr.TS.tx(storage, [{0, {:sdiffstore, "result", ["set1", "set2", "set3"]}}])

      {:ok, result_members} = Vdr.TS.smembers(storage, 0, "result")
      assert Enum.sort(result_members) == ["a", "e"]
    end

    test "handles non-existent subtract sets", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "set1", ["a", "b", "c"]}}])

      [:ok] = Vdr.TS.tx(storage, [{0, {:sdiffstore, "result", ["set1", "nonexistent"]}}])

      {:ok, result_members} = Vdr.TS.smembers(storage, 0, "result")
      assert Enum.sort(result_members) == ["a", "b", "c"]
    end

    test "returns error on type mismatch", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:set, "mystring", "value"}}])
      Vdr.TS.tx(storage, [{0, {:sadd, "myset", ["a"]}}])

      [{:error, :wrong_type}] =
        Vdr.TS.tx(storage, [{0, {:sdiffstore, "result", ["myset", "mystring"]}}])
    end
  end

  describe "smembers/3" do
    test "returns all members of a set", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c"]}}])

      {:ok, members} = Vdr.TS.smembers(storage, 0, "myset")
      assert Enum.sort(members) == ["a", "b", "c"]
    end

    test "returns empty list for non-existent key", %{storage: storage} do
      assert {:ok, []} = Vdr.TS.smembers(storage, 0, "nonexistent")
    end

    test "returns error on type mismatch", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:set, "mystring", "value"}}])
      assert {:error, :wrong_type} = Vdr.TS.smembers(storage, 0, "mystring")
    end
  end

  describe "sismember/4" do
    test "returns true for existing member", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c"]}}])

      assert {:ok, true} = Vdr.TS.sismember(storage, 0, "myset", "b")
    end

    test "returns false for non-existent member", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "myset", ["a", "b"]}}])

      assert {:ok, false} = Vdr.TS.sismember(storage, 0, "myset", "z")
    end

    test "returns false for non-existent key", %{storage: storage} do
      assert {:ok, false} = Vdr.TS.sismember(storage, 0, "nonexistent", "a")
    end

    test "returns error on type mismatch", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:set, "mystring", "value"}}])
      assert {:error, :wrong_type} = Vdr.TS.sismember(storage, 0, "mystring", "a")
    end
  end

  describe "scard/3" do
    test "returns cardinality of a set", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "myset", ["a", "b", "c", "d"]}}])

      assert {:ok, 4} = Vdr.TS.scard(storage, 0, "myset")
    end

    test "returns 0 for non-existent key", %{storage: storage} do
      assert {:ok, 0} = Vdr.TS.scard(storage, 0, "nonexistent")
    end

    test "returns 0 after removing all members", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "myset", ["a", "b"]}}])
      Vdr.TS.tx(storage, [{0, {:srem, "myset", ["a", "b"]}}])

      assert {:ok, 0} = Vdr.TS.scard(storage, 0, "myset")
    end

    test "returns error on type mismatch", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:set, "mystring", "value"}}])
      assert {:error, :wrong_type} = Vdr.TS.scard(storage, 0, "mystring")
    end
  end

  describe "binary safety" do
    test "handles binary members with null bytes", %{storage: storage} do
      binary_member = <<0, 1, 2, 255, 254, 253>>
      Vdr.TS.tx(storage, [{0, {:sadd, "binset", [binary_member, "normal"]}}])

      {:ok, members} = Vdr.TS.smembers(storage, 0, "binset")
      assert binary_member in members
      assert "normal" in members
    end

    test "handles UTF-8 members", %{storage: storage} do
      Vdr.TS.tx(storage, [{0, {:sadd, "utf8set", ["hello", "世界", "🚀"]}}])

      {:ok, members} = Vdr.TS.smembers(storage, 0, "utf8set")
      assert Enum.sort(members) == ["hello", "世界", "🚀"] |> Enum.sort()
    end
  end
end
