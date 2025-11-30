defmodule Vdr.RDBTest do
  use ExUnit.Case, async: true

  @behaviour Vdr.RedisStream.Callback

  alias Vdr.Command

  @moduledoc """
  Tests for RDB parsing with various Redis data types.
  """

  # Callback implementation that collects all parsed commands
  @impl true
  def on_command(state, db, %Command.Set{key: key, value: value}) do
    strings = Map.get(state, :strings, [])
    {:ok, Map.put(state, :strings, [{db, key, value} | strings])}
  end

  def on_command(state, db, %Command.RPush{key: key, values: values}) do
    lists = Map.get(state, :lists, [])
    # Expand each value into a separate entry
    new_entries = Enum.map(values, fn value -> {db, key, value} end)
    {:ok, Map.put(state, :lists, new_entries ++ lists)}
  end

  def on_command(state, db, %Command.SAdd{key: key, members: members}) do
    sets = Map.get(state, :sets, [])
    # Expand each member into a separate entry
    new_entries = Enum.map(members, fn member -> {db, key, member} end)
    {:ok, Map.put(state, :sets, new_entries ++ sets)}
  end

  def on_command(state, db, %Command.ZAdd{key: key, members: members}) do
    zsets = Map.get(state, :zsets, [])
    # Expand each score/member pair into a separate entry
    new_entries = Enum.map(members, fn {score, member} -> {db, key, member, score} end)
    {:ok, Map.put(state, :zsets, new_entries ++ zsets)}
  end

  def on_command(state, db, %Command.HSet{key: key, fields: fields}) do
    hashes = Map.get(state, :hashes, [])
    # Expand each field/value pair into a separate entry
    new_entries = Enum.map(fields, fn {field, value} -> {db, key, field, value} end)
    {:ok, Map.put(state, :hashes, new_entries ++ hashes)}
  end

  def on_command(state, _db, %Command.PExpireAt{}) do
    # For testing, we just ignore expire commands
    {:ok, state}
  end

  # Setup - parse the RDB file once for all tests
  setup_all do
    dump_file = Path.join([File.cwd!(), "test", "assets", "dump.rdb"])

    case File.read(dump_file) do
      {:ok, rdb_binary} ->
        initial_state = %{strings: [], sets: [], zsets: [], lists: [], hashes: []}
        {:ok, final_state} = Vdr.RDB.parse(rdb_binary, __MODULE__, initial_state)
        {:ok, parsed: final_state}

      {:error, _} ->
        {:ok, skip: true}
    end
  end

  describe "string parsing" do
    test "parses integer-encoded string", %{parsed: state} do
      strings = Map.get(state, :strings)

      assert {0, "str_int", "1234567890"} in strings
    end

    test "parses embstr string", %{parsed: state} do
      strings = Map.get(state, :strings)

      assert {0, "str_embstr", "this is a short embstr string"} in strings
    end

    test "parses raw string", %{parsed: state} do
      strings = Map.get(state, :strings)

      {0, "str_raw", raw_str} = Enum.find(strings, fn {_, k, _} -> k == "str_raw" end)
      assert is_binary(raw_str)
      assert raw_str =~ "This string is intentionally made very long"
    end

    test "parses LZF-compressed string", %{parsed: state} do
      strings = Map.get(state, :strings)

      {0, "str_compressible_lzf", comp_str} =
        Enum.find(strings, fn {_, k, _} -> k == "str_compressible_lzf" end)

      # Should be 1000 'a's
      assert byte_size(comp_str) >= 1000
      assert String.to_charlist(comp_str) |> Enum.all?(&(&1 == ?a))
    end
  end

  describe "list parsing" do
    test "parses listpack-encoded list", %{parsed: state} do
      lists = Map.get(state, :lists)

      listpack_entries =
        lists
        |> Enum.filter(fn {_, k, _} -> k == "list_listpack" end)
        |> Enum.map(fn {_, _, v} -> v end)

      assert length(listpack_entries) == 5
      assert "first" in listpack_entries
      assert "second" in listpack_entries
      assert "third" in listpack_entries
      assert "4" in listpack_entries
      assert "five" in listpack_entries
    end

    test "parses quicklist with big element (LZF compressed)", %{parsed: state} do
      lists = Map.get(state, :lists)

      big_list_entries =
        lists
        |> Enum.filter(fn {_, k, _} -> k == "list_quicklist_big_element" end)
        |> Enum.map(fn {_, _, v} -> v end)

      assert length(big_list_entries) == 1
      [big_elem] = big_list_entries
      assert byte_size(big_elem) > 100
      assert big_elem =~ "This single element"
      assert big_elem =~ "list-max-listpack-size"
    end

    test "parses quicklist with many elements", %{parsed: state} do
      lists = Map.get(state, :lists)

      many_list_entries =
        lists
        |> Enum.filter(fn {_, k, _} -> k == "list_quicklist_many_elements" end)
        |> Enum.map(fn {_, _, v} -> v end)

      assert length(many_list_entries) == 78
      assert "a" in many_list_entries
      assert "z" in many_list_entries
      assert "a1" in many_list_entries
      assert "z2" in many_list_entries
    end

    test "parses guaranteed quicklist", %{parsed: state} do
      lists = Map.get(state, :lists)

      quicklist_entries =
        lists
        |> Enum.filter(fn {_, k, _} -> k == "list_guaranteed_quicklist" end)
        |> Enum.map(fn {_, _, v} -> v end)

      assert length(quicklist_entries) == 3
      assert "alpha" in quicklist_entries
      assert "beta" in quicklist_entries
      assert "gamma" in quicklist_entries
    end
  end

  describe "hash parsing" do
    test "parses listpack-encoded hash", %{parsed: state} do
      hashes = Map.get(state, :hashes)

      hash_entries =
        hashes
        |> Enum.filter(fn {_, k, _, _} -> k == "hash_listpack" end)
        |> Enum.map(fn {_, _, f, v} -> {f, v} end)

      assert length(hash_entries) == 3
      assert {"field1", "value1"} in hash_entries
      assert {"name", "redis"} in hash_entries
      assert {"version", "7.2"} in hash_entries
    end

    test "parses hashtable-encoded hash", %{parsed: state} do
      hashes = Map.get(state, :hashes)

      hash_entries =
        hashes
        |> Enum.filter(fn {_, k, _, _} -> k == "hash_hashtable" end)
        |> Enum.map(fn {_, _, f, v} -> {f, v} end)

      assert length(hash_entries) == 2
      assert {"field1", "value1"} in hash_entries

      {_, field2_val} = Enum.find(hash_entries, fn {f, _} -> f == "field2" end)
      assert byte_size(field2_val) > 100
      assert field2_val =~ "extremely long"
    end
  end

  describe "set parsing" do
    test "parses intset-encoded set", %{parsed: state} do
      sets = Map.get(state, :sets)

      intset_entries =
        sets
        |> Enum.filter(fn {_, k, _} -> k == "set_intset" end)
        |> Enum.map(fn {_, _, e} -> String.to_integer(e) end)

      assert length(intset_entries) == 6
      assert 100 in intset_entries
      assert 200 in intset_entries
      assert 300 in intset_entries
      assert 42 in intset_entries
      assert 999 in intset_entries
      assert 10000 in intset_entries
    end

    test "parses hashtable-encoded set", %{parsed: state} do
      sets = Map.get(state, :sets)

      set_entries =
        sets
        |> Enum.filter(fn {_, k, _} -> k == "set_hashtable" end)
        |> Enum.map(fn {_, _, e} -> e end)

      assert length(set_entries) == 5
      assert "apple" in set_entries
      assert "banana" in set_entries
      assert "cherry" in set_entries
      assert "123" in set_entries
      assert "another-string" in set_entries
    end
  end

  describe "sorted set parsing" do
    test "parses listpack-encoded zset", %{parsed: state} do
      zsets = Map.get(state, :zsets)

      zset_entries =
        zsets
        |> Enum.filter(fn {_, k, _, _} -> k == "zset_listpack" end)
        |> Enum.map(fn {_, _, m, s} -> {m, s} end)

      assert length(zset_entries) == 3
      assert {"one", 1.0} in zset_entries
      assert {"two", 2.0} in zset_entries
      assert {"three", 3.0} in zset_entries
    end

    test "parses skiplist-encoded zset", %{parsed: state} do
      zsets = Map.get(state, :zsets)

      zset_entries =
        zsets
        |> Enum.filter(fn {_, k, _, _} -> k == "zset_skiplist" end)
        |> Enum.map(fn {_, _, m, s} -> {m, s} end)

      assert length(zset_entries) == 3
      assert {"member_one", 1.0} in zset_entries
      assert {"member_two", 2.0} in zset_entries

      {long_member, 3.0} = Enum.find(zset_entries, fn {_, s} -> s == 3.0 end)
      assert byte_size(long_member) > 100
      assert long_member =~ "exceptionally long"
    end
  end

  describe "streaming API" do
    test "parses RDB file in single chunk" do
      dump_file = Path.join([File.cwd!(), "test", "assets", "dump.rdb"])
      {:ok, rdb_binary} = File.read(dump_file)

      initial_state = %{strings: []}
      parser = Vdr.RDB.create(__MODULE__, initial_state)

      {:ok, parser} = Vdr.RDB.data(parser, rdb_binary)
      {:ok, final_state} = Vdr.RDB.finish(parser)

      strings = Map.get(final_state, :strings)
      assert length(strings) > 0
      assert {0, "str_int", "1234567890"} in strings
    end

    test "parses RDB file in multiple chunks" do
      dump_file = Path.join([File.cwd!(), "test", "assets", "dump.rdb"])
      {:ok, rdb_binary} = File.read(dump_file)

      # Split into chunks of 10 bytes
      chunks = split_into_chunks(rdb_binary, 10)

      initial_state = %{strings: []}
      parser = Vdr.RDB.create(__MODULE__, initial_state)

      # Feed all chunks
      parser =
        Enum.reduce(chunks, parser, fn chunk, acc_parser ->
          case Vdr.RDB.data(acc_parser, chunk) do
            {:ok, new_parser} -> new_parser
            {:error, :already_finished} -> acc_parser
          end
        end)

      {:ok, final_state} = Vdr.RDB.finish(parser)

      strings = Map.get(final_state, :strings)
      assert length(strings) > 0
      assert {0, "str_int", "1234567890"} in strings
    end

    test "parses RDB file in very small chunks" do
      dump_file = Path.join([File.cwd!(), "test", "assets", "dump.rdb"])
      {:ok, rdb_binary} = File.read(dump_file)

      # Split into chunks of 3 bytes (very small)
      chunks = split_into_chunks(rdb_binary, 3)

      initial_state = %{strings: [], lists: []}
      parser = Vdr.RDB.create(__MODULE__, initial_state)

      # Feed all chunks
      parser =
        Enum.reduce(chunks, parser, fn chunk, acc_parser ->
          case Vdr.RDB.data(acc_parser, chunk) do
            {:ok, new_parser} -> new_parser
            {:error, :already_finished} -> acc_parser
          end
        end)

      {:ok, final_state} = Vdr.RDB.finish(parser)

      strings = Map.get(final_state, :strings)
      lists = Map.get(final_state, :lists)
      assert length(strings) > 0
      assert length(lists) > 0
    end

    test "returns error when finish called before EOF" do
      # Create a partial RDB file (just the header)
      partial_rdb = <<"REDIS", "0012">>

      initial_state = %{}
      parser = Vdr.RDB.create(__MODULE__, initial_state)

      {:ok, parser} = Vdr.RDB.data(parser, partial_rdb)

      # Should return error because we haven't reached EOF
      assert {:error, :incomplete_rdb} = Vdr.RDB.finish(parser)
    end

    test "returns error when data called after finish" do
      # Create minimal valid RDB (header + EOF)
      minimal_rdb = <<"REDIS", "0012", 255>>

      initial_state = %{}
      parser = Vdr.RDB.create(__MODULE__, initial_state)

      {:ok, parser} = Vdr.RDB.data(parser, minimal_rdb)
      {:ok, _final_state} = Vdr.RDB.finish(parser)

      # Should return error when trying to feed more data
      assert {:error, :already_finished} = Vdr.RDB.data(parser, <<>>)
    end

    test "accumulates chunks without binary concatenation" do
      dump_file = Path.join([File.cwd!(), "test", "assets", "dump.rdb"])
      {:ok, rdb_binary} = File.read(dump_file)

      # Split into random-sized chunks
      chunks = split_into_random_chunks(rdb_binary, 5, 30)

      initial_state = %{strings: [], lists: [], hashes: []}
      parser = Vdr.RDB.create(__MODULE__, initial_state)

      # Feed all chunks
      parser =
        Enum.reduce(chunks, parser, fn chunk, acc_parser ->
          case Vdr.RDB.data(acc_parser, chunk) do
            {:ok, new_parser} -> new_parser
            {:error, :already_finished} -> acc_parser
          end
        end)

      {:ok, final_state} = Vdr.RDB.finish(parser)

      # Verify all data was parsed correctly
      strings = Map.get(final_state, :strings)
      lists = Map.get(final_state, :lists)
      hashes = Map.get(final_state, :hashes)

      assert length(strings) > 0
      assert length(lists) > 0
      assert length(hashes) > 0
    end

    test "get_state and put_state accessor methods" do
      dump_file = Path.join([File.cwd!(), "test", "assets", "dump.rdb"])
      {:ok, rdb_binary} = File.read(dump_file)

      # Split into two chunks
      chunk_size = div(byte_size(rdb_binary), 2)
      <<chunk1::binary-size(chunk_size), chunk2::binary>> = rdb_binary

      initial_state = %{strings: [], count: 0}
      parser = Vdr.RDB.create(__MODULE__, initial_state)

      # Feed first chunk
      {:ok, parser} = Vdr.RDB.data(parser, chunk1)

      # Get intermediate state
      intermediate_state = Vdr.RDB.get_state(parser)
      assert is_map(intermediate_state)
      assert Map.has_key?(intermediate_state, :strings)
      assert Map.has_key?(intermediate_state, :count)

      # Modify state externally
      modified_state = Map.put(intermediate_state, :count, 999)
      parser = Vdr.RDB.put_state(parser, modified_state)

      # Verify state was updated
      assert Vdr.RDB.get_state(parser).count == 999

      # Feed second chunk
      {:ok, parser} = Vdr.RDB.data(parser, chunk2)

      # Finish and verify final state includes our modification
      {:ok, final_state} = Vdr.RDB.finish(parser)
      assert final_state.count == 999
      assert length(final_state.strings) > 0
    end
  end

  # Helper to split binary into fixed-size chunks
  defp split_into_chunks(binary, chunk_size) do
    do_split_chunks(binary, chunk_size, [])
  end

  defp do_split_chunks(<<>>, _chunk_size, acc), do: Enum.reverse(acc)

  defp do_split_chunks(binary, chunk_size, acc) when byte_size(binary) <= chunk_size do
    Enum.reverse([binary | acc])
  end

  defp do_split_chunks(binary, chunk_size, acc) do
    <<chunk::binary-size(chunk_size), rest::binary>> = binary
    do_split_chunks(rest, chunk_size, [chunk | acc])
  end

  # Helper to split binary into random-sized chunks
  defp split_into_random_chunks(binary, min_size, max_size) do
    do_split_random_chunks(binary, min_size, max_size, [])
  end

  defp do_split_random_chunks(<<>>, _min, _max, acc), do: Enum.reverse(acc)

  defp do_split_random_chunks(binary, _min, max, acc) when byte_size(binary) <= max do
    Enum.reverse([binary | acc])
  end

  defp do_split_random_chunks(binary, min, max, acc) do
    chunk_size = min + :rand.uniform(max - min + 1) - 1
    chunk_size = min(chunk_size, byte_size(binary))
    <<chunk::binary-size(chunk_size), rest::binary>> = binary
    do_split_random_chunks(rest, min, max, [chunk | acc])
  end
end
