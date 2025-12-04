defmodule VDR.ETSReadTest do
  use ExUnit.Case, async: true

  alias VDR.ETSRead

  describe "match_stream/3" do
    test "streams matched objects in forward order" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:key1, "value1"})
      :ets.insert(tid, {:key2, "value2"})
      :ets.insert(tid, {:key3, "value3"})

      result = ETSRead.match_stream(tid, {:"$1", :"$2"}, 2) |> Enum.to_list()

      assert length(result) == 3
      assert [:key1, "value1"] in result
      assert [:key2, "value2"] in result
      assert [:key3, "value3"] in result

      :ets.delete(tid)
    end

    test "returns empty stream for empty table" do
      tid = :ets.new(:test, [:ordered_set, :public])

      result = ETSRead.match_stream(tid, {:"$1", :"$2"}, 10) |> Enum.to_list()

      assert result == []
      :ets.delete(tid)
    end

    test "uses default limit of 1" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:key1, "value1"})

      result = ETSRead.match_stream(tid, {:"$1", :"$2"}) |> Enum.to_list()

      assert result == [[:key1, "value1"]]
      :ets.delete(tid)
    end
  end

  describe "match_rev_stream/3" do
    test "streams matched objects in reverse order" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:key1, "value1"})
      :ets.insert(tid, {:key2, "value2"})
      :ets.insert(tid, {:key3, "value3"})

      result = ETSRead.match_rev_stream(tid, {:"$1", :"$2"}, 10) |> Enum.to_list()

      assert result == [[:key3, "value3"], [:key2, "value2"], [:key1, "value1"]]
      :ets.delete(tid)
    end

    test "returns empty stream for empty table" do
      tid = :ets.new(:test, [:ordered_set, :public])

      result = ETSRead.match_rev_stream(tid, {:"$1", :"$2"}, 10) |> Enum.to_list()

      assert result == []
      :ets.delete(tid)
    end
  end

  describe "select_stream/3" do
    test "streams selected objects in forward order" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:key1, "value1"})
      :ets.insert(tid, {:key2, "value2"})
      :ets.insert(tid, {:key3, "value3"})

      match_spec = [{{:"$1", :"$2"}, [], [[:"$1", :"$2"]]}]
      result = ETSRead.select_stream(tid, match_spec, 2) |> Enum.to_list()

      assert length(result) == 3
      assert [:key1, "value1"] in result
      assert [:key2, "value2"] in result
      assert [:key3, "value3"] in result

      :ets.delete(tid)
    end

    test "filters results using match spec conditions" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:key1, 10})
      :ets.insert(tid, {:key2, 20})
      :ets.insert(tid, {:key3, 30})

      match_spec = [{{:"$1", :"$2"}, [{:>, :"$2", 15}], [[:"$1", :"$2"]]}]
      result = ETSRead.select_stream(tid, match_spec, 10) |> Enum.to_list()

      assert result == [[:key2, 20], [:key3, 30]]
      :ets.delete(tid)
    end
  end

  describe "select_rev_stream/3" do
    test "streams selected objects in reverse order" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:key1, "value1"})
      :ets.insert(tid, {:key2, "value2"})
      :ets.insert(tid, {:key3, "value3"})

      match_spec = [{{:"$1", :"$2"}, [], [[:"$1", :"$2"]]}]
      result = ETSRead.select_rev_stream(tid, match_spec, 10) |> Enum.to_list()

      assert result == [[:key3, "value3"], [:key2, "value2"], [:key1, "value1"]]
      :ets.delete(tid)
    end

    test "filters results using match spec conditions in reverse" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:key1, 10})
      :ets.insert(tid, {:key2, 20})
      :ets.insert(tid, {:key3, 30})

      match_spec = [{{:"$1", :"$2"}, [{:>, :"$2", 15}], [[:"$1", :"$2"]]}]
      result = ETSRead.select_rev_stream(tid, match_spec, 10) |> Enum.to_list()

      assert result == [[:key3, 30], [:key2, 20]]
      :ets.delete(tid)
    end
  end

  describe "first_key/2" do
    test "finds first key matching pattern" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {{:user, :profile, 1}, "value1"})
      :ets.insert(tid, {{:user, :profile, 2}, "value2"})
      :ets.insert(tid, {{:user, :other, 1}, "value3"})

      result = ETSRead.first_key(tid, {{:user, :profile, :_}, :_})

      assert result == {:user, :profile, 1}
      :ets.delete(tid)
    end

    test "returns nil when no match found" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {{:user, :other, 1}, "value1"})

      result = ETSRead.first_key(tid, {{:user, :profile, :_}, :_})

      assert result == nil
      :ets.delete(tid)
    end

    test "returns nil for empty table" do
      tid = :ets.new(:test, [:ordered_set, :public])

      result = ETSRead.first_key(tid, {{:user, :profile, :_}, :_})

      assert result == nil
      :ets.delete(tid)
    end

    test "works with simple key patterns" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:a, 1})
      :ets.insert(tid, {:b, 2})
      :ets.insert(tid, {:c, 3})

      result = ETSRead.first_key(tid, {:b, :_})

      assert result == :b
      :ets.delete(tid)
    end
  end

  describe "last_key/2" do
    test "finds last key matching pattern" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {{:user, :profile, 1}, "value1"})
      :ets.insert(tid, {{:user, :profile, 2}, "value2"})
      :ets.insert(tid, {{:user, :other, 1}, "value3"})

      result = ETSRead.last_key(tid, {{:user, :profile, :_}, :_})

      assert result == {:user, :profile, 2}
      :ets.delete(tid)
    end

    test "returns nil when no match found" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {{:user, :other, 1}, "value1"})

      result = ETSRead.last_key(tid, {{:user, :profile, :_}, :_})

      assert result == nil
      :ets.delete(tid)
    end

    test "returns nil for empty table" do
      tid = :ets.new(:test, [:ordered_set, :public])

      result = ETSRead.last_key(tid, {{:user, :profile, :_}, :_})

      assert result == nil
      :ets.delete(tid)
    end

    test "works with simple key patterns" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:a, 1})
      :ets.insert(tid, {:b, 2})
      :ets.insert(tid, {:c, 3})

      result = ETSRead.last_key(tid, {:b, :_})

      assert result == :b
      :ets.delete(tid)
    end
  end

  describe "key_range_stream/3" do
    test "streams objects in key range forward" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:key1, "value1"})
      :ets.insert(tid, {:key2, "value2"})
      :ets.insert(tid, {:key3, "value3"})
      :ets.insert(tid, {:key4, "value4"})

      result = ETSRead.key_range_stream(tid, :key2, :key3) |> Enum.to_list()

      assert result == [{:key2, "value2"}, {:key3, "value3"}]
      :ets.delete(tid)
    end

    test "includes both endpoints" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:key1, "value1"})
      :ets.insert(tid, {:key2, "value2"})

      result = ETSRead.key_range_stream(tid, :key1, :key2) |> Enum.to_list()

      assert result == [{:key1, "value1"}, {:key2, "value2"}]
      :ets.delete(tid)
    end

    test "returns single element when start equals end" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:key1, "value1"})
      :ets.insert(tid, {:key2, "value2"})

      result = ETSRead.key_range_stream(tid, :key2, :key2) |> Enum.to_list()

      assert result == [{:key2, "value2"}]
      :ets.delete(tid)
    end

    test "returns empty stream when start key not found" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:key1, "value1"})

      result = ETSRead.key_range_stream(tid, :key2, :key3) |> Enum.to_list()

      assert result == []
      :ets.delete(tid)
    end

    test "stops at end key even if more keys exist" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:key1, "value1"})
      :ets.insert(tid, {:key2, "value2"})
      :ets.insert(tid, {:key3, "value3"})
      :ets.insert(tid, {:key4, "value4"})

      result = ETSRead.key_range_stream(tid, :key1, :key2) |> Enum.to_list()

      assert result == [{:key1, "value1"}, {:key2, "value2"}]
      :ets.delete(tid)
    end

    test "works with tuple keys" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {{:user, 1}, "value1"})
      :ets.insert(tid, {{:user, 2}, "value2"})
      :ets.insert(tid, {{:user, 3}, "value3"})

      result = ETSRead.key_range_stream(tid, {:user, 1}, {:user, 2}) |> Enum.to_list()

      assert result == [{{:user, 1}, "value1"}, {{:user, 2}, "value2"}]
      :ets.delete(tid)
    end
  end

  describe "key_rev_range_stream/3" do
    test "streams objects in key range reverse" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:key1, "value1"})
      :ets.insert(tid, {:key2, "value2"})
      :ets.insert(tid, {:key3, "value3"})
      :ets.insert(tid, {:key4, "value4"})

      result = ETSRead.key_rev_range_stream(tid, :key3, :key2) |> Enum.to_list()

      assert result == [{:key3, "value3"}, {:key2, "value2"}]
      :ets.delete(tid)
    end

    test "includes both endpoints" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:key1, "value1"})
      :ets.insert(tid, {:key2, "value2"})

      result = ETSRead.key_rev_range_stream(tid, :key2, :key1) |> Enum.to_list()

      assert result == [{:key2, "value2"}, {:key1, "value1"}]
      :ets.delete(tid)
    end

    test "returns single element when start equals end" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:key1, "value1"})
      :ets.insert(tid, {:key2, "value2"})

      result = ETSRead.key_rev_range_stream(tid, :key2, :key2) |> Enum.to_list()

      assert result == [{:key2, "value2"}]
      :ets.delete(tid)
    end

    test "returns elements even when start key not found" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:key1, "value1"})

      result = ETSRead.key_rev_range_stream(tid, :key2, :key1) |> Enum.to_list()

      assert result == [{:key1, "value1"}]
      :ets.delete(tid)
    end

    test "stops at end key even if more keys exist" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {:key1, "value1"})
      :ets.insert(tid, {:key2, "value2"})
      :ets.insert(tid, {:key3, "value3"})
      :ets.insert(tid, {:key4, "value4"})

      result = ETSRead.key_rev_range_stream(tid, :key4, :key3) |> Enum.to_list()

      assert result == [{:key4, "value4"}, {:key3, "value3"}]
      :ets.delete(tid)
    end

    test "works with tuple keys" do
      tid = :ets.new(:test, [:ordered_set, :public])
      :ets.insert(tid, {{:user, 1}, "value1"})
      :ets.insert(tid, {{:user, 2}, "value2"})
      :ets.insert(tid, {{:user, 3}, "value3"})

      result = ETSRead.key_rev_range_stream(tid, {:user, 3}, {:user, 2}) |> Enum.to_list()

      assert result == [{{:user, 3}, "value3"}, {{:user, 2}, "value2"}]
      :ets.delete(tid)
    end
  end
end
