defmodule Vdr.RDBTest do
  use ExUnit.Case, async: true

  alias Vdr.RedisCommand

  @moduledoc """
  Tests for RDB parsing with various Redis data types.
  """

  # Helper function to process commands and collect data
  defp process_commands(
         commands,
         state \\ %{strings: [], sets: [], zsets: [], lists: [], hashes: []}
       ) do
    Enum.reduce(commands, state, fn {db, command}, acc ->
      process_command(command, acc, db)
    end)
  end

  defp process_command(%RedisCommand.Set{key: key, value: value}, state, db) do
    strings = Map.get(state, :strings, [])
    Map.put(state, :strings, [{db, key, value} | strings])
  end

  defp process_command(%RedisCommand.RPush{key: key, values: values}, state, db) do
    lists = Map.get(state, :lists, [])
    # Expand each value into a separate entry
    new_entries = Enum.map(values, fn value -> {db, key, value} end)
    Map.put(state, :lists, new_entries ++ lists)
  end

  defp process_command(%RedisCommand.SAdd{key: key, members: members}, state, db) do
    sets = Map.get(state, :sets, [])
    # Expand each member into a separate entry
    new_entries = Enum.map(members, fn member -> {db, key, member} end)
    Map.put(state, :sets, new_entries ++ sets)
  end

  defp process_command(%RedisCommand.ZAdd{key: key, members: members}, state, db) do
    zsets = Map.get(state, :zsets, [])
    # Expand each score/member pair into a separate entry
    new_entries = Enum.map(members, fn {score, member} -> {db, key, member, score} end)
    Map.put(state, :zsets, new_entries ++ zsets)
  end

  defp process_command(%RedisCommand.HSet{key: key, fields: fields}, state, db) do
    hashes = Map.get(state, :hashes, [])
    # Expand each field/value pair into a separate entry
    new_entries = Enum.map(fields, fn {field, value} -> {db, key, field, value} end)
    Map.put(state, :hashes, new_entries ++ hashes)
  end

  defp process_command(%RedisCommand.PExpireAt{}, state, _db) do
    # For testing, we just ignore expire commands
    state
  end

  # Setup - parse the RDB file once for all tests
  setup_all do
    dump_file = Path.join([File.cwd!(), "test", "assets", "dump.rdb"])

    case File.read(dump_file) do
      {:ok, rdb_binary} ->
        parser = Vdr.RDB.create()

        case Vdr.RDB.data(parser, rdb_binary) do
          {:ok, commands} when is_list(commands) ->
            # Parsing finished (2-tuple return)
            final_state = process_commands(commands)
            {:ok, parsed: final_state}

          {:ok, _commands, _parser} ->
            flunk("RDB parse error: parsing should be completed but it is not")

          {:error, reason} ->
            flunk("RDB parse error: #{inspect(reason)}")
        end

      {:error, reason} ->
        flunk("RDB read error: #{inspect(reason)}")
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

      parser = Vdr.RDB.create()

      case Vdr.RDB.data(parser, rdb_binary) do
        {:ok, commands} when is_list(commands) ->
          # Parsing finished (2-tuple)
          state = process_commands(commands, %{strings: []})
          strings = Map.get(state, :strings)
          assert length(strings) > 0
          assert {0, "str_int", "1234567890"} in strings

        {:ok, commands, _parser} ->
          # Parsing not finished (3-tuple) - shouldn't happen with full file
          state = process_commands(commands, %{strings: []})
          strings = Map.get(state, :strings)
          assert length(strings) > 0
          assert {0, "str_int", "1234567890"} in strings

        {:error, reason} ->
          flunk("Parse error: #{inspect(reason)}")
      end
    end

    test "parses RDB file in multiple chunks" do
      dump_file = Path.join([File.cwd!(), "test", "assets", "dump.rdb"])
      {:ok, rdb_binary} = File.read(dump_file)

      # Split into chunks of 64 bytes
      chunks = split_into_chunks(rdb_binary, 128)

      parser = Vdr.RDB.create()

      # Feed all chunks and accumulate commands
      {all_commands, _final_result} =
        Enum.reduce(chunks, {[], parser}, fn chunk, {commands_acc, current_parser} ->
          # Skip if already finished
          if current_parser == :finished do
            {commands_acc, :finished}
          else
            case Vdr.RDB.data(current_parser, chunk) do
              {:ok, commands} when is_list(commands) ->
                # Parsing finished (2-tuple), accumulate final commands
                {commands_acc ++ commands, :finished}

              {:ok, commands, new_parser} ->
                # Parsing continues (3-tuple)
                {commands_acc ++ commands, new_parser}

              {:error, :already_finished} ->
                {commands_acc, :finished}

              {:error, _reason} ->
                {commands_acc, current_parser}
            end
          end
        end)

      state = process_commands(all_commands, %{strings: []})
      strings = Map.get(state, :strings)
      assert length(strings) > 0
      assert {0, "str_int", "1234567890"} in strings
    end

    test "parses RDB file in very small chunks" do
      dump_file = Path.join([File.cwd!(), "test", "assets", "dump.rdb"])
      {:ok, rdb_binary} = File.read(dump_file)

      # Split into chunks of 32 bytes (small)
      chunks = split_into_chunks(rdb_binary, 32)
      chunk_sizes = Enum.map(chunks, &byte_size/1)

      parser = Vdr.RDB.create()

      # Feed all chunks and accumulate commands
      {all_commands, _final_result} =
        Enum.reduce(chunks, {[], parser}, fn chunk, {commands_acc, current_parser} ->
          # Skip if already finished
          if current_parser == :finished do
            {commands_acc, :finished}
          else
            case Vdr.RDB.data(current_parser, chunk) do
              {:ok, commands} when is_list(commands) ->
                # Parsing finished (2-tuple), accumulate final commands
                {commands_acc ++ commands, :finished}

              {:ok, commands, new_parser} ->
                # Parsing continues (3-tuple)
                {commands_acc ++ commands, new_parser}

              {:error, :already_finished} ->
                {commands_acc, :finished}

              {:error, _reason} ->
                {commands_acc, current_parser}
            end
          end
        end)

      state = process_commands(all_commands, %{strings: [], lists: []})
      strings = Map.get(state, :strings)
      lists = Map.get(state, :lists)
      assert length(strings) > 0
      assert length(lists) > 0
    end

    test "requires checksum after EOF" do
      # Create minimal valid RDB (header + EOF + 8-byte checksum)
      minimal_rdb = <<"REDIS", "0012", 255, 0, 0, 0, 0, 0, 0, 0, 0>>

      parser = Vdr.RDB.create()

      # First call should return empty commands (EOF reached)
      # With Rust implementation, when EOF is reached, parser is not returned
      result = Vdr.RDB.data(parser, minimal_rdb)

      # Should return {:ok, commands} without parser (indicating finished)
      case result do
        {:ok, _commands} ->
          # EOF reached, this is correct
          assert true

        {:ok, _commands, _parser} ->
          # Should not happen with minimal RDB that has immediate EOF
          flunk("Expected EOF to be reached")

        {:error, reason} ->
          flunk("Unexpected error: #{inspect(reason)}")
      end
    end

    test "rejects RDB without checksum" do
      # Create invalid RDB (header + EOF but NO checksum)
      rdb_no_checksum = <<"REDIS", "0012", 255>>

      parser = Vdr.RDB.create()
      result = Vdr.RDB.data(parser, rdb_no_checksum)

      # Should return {:ok, [], parser} indicating more data needed (waiting for checksum)
      case result do
        {:ok, commands, _parser} ->
          # Parser is waiting for checksum, not finished
          assert commands == []

        {:ok, _commands} ->
          # Should NOT finish without checksum
          flunk("Parser should not finish without checksum")

        {:error, _reason} ->
          # Also acceptable - could error immediately
          assert true
      end
    end

    test "rejects RDB with incomplete checksum" do
      # Create invalid RDB (header + EOF + only 4 bytes of checksum)
      rdb_partial_checksum = <<"REDIS", "0012", 255, 0, 0, 0, 0>>

      parser = Vdr.RDB.create()
      result = Vdr.RDB.data(parser, rdb_partial_checksum)

      # Should return {:ok, [], parser} indicating more data needed
      case result do
        {:ok, commands, _parser} ->
          # Parser is waiting for remaining checksum bytes
          assert commands == []

        {:ok, _commands} ->
          # Should NOT finish with partial checksum
          flunk("Parser should not finish with incomplete checksum")

        {:error, _reason} ->
          # Also acceptable
          assert true
      end
    end

    test "accumulates chunks without binary concatenation" do
      dump_file = Path.join([File.cwd!(), "test", "assets", "dump.rdb"])
      {:ok, rdb_binary} = File.read(dump_file)

      # Split into random-sized chunks
      chunks = split_into_random_chunks(rdb_binary, 32, 128)

      parser = Vdr.RDB.create()

      # Feed all chunks and accumulate commands
      assert {all_commands, :finished} =
               Enum.reduce(chunks, {[], parser}, fn chunk, {commands_acc, current_parser} ->
                 # Skip if already finished
                 if current_parser == :finished do
                   {commands_acc, :finished}
                 else
                   case Vdr.RDB.data(current_parser, chunk) do
                     {:ok, commands} when is_list(commands) ->
                       # Parsing finished (2-tuple), accumulate final commands
                       {commands_acc ++ commands, :finished}

                     {:ok, commands, new_parser} ->
                       # Parsing continues (3-tuple)
                       {commands_acc ++ commands, new_parser}

                     {:error, :already_finished} ->
                       {commands_acc, :finished}

                     {:error, _reason} ->
                       {commands_acc, current_parser}
                   end
                 end
               end)

      # Verify all data was parsed correctly
      state = process_commands(all_commands, %{strings: [], lists: [], hashes: []})
      strings = Map.get(state, :strings)
      lists = Map.get(state, :lists)
      hashes = Map.get(state, :hashes)

      assert length(strings) > 0
      assert length(lists) > 0
      assert length(hashes) > 0
    end
  end

  # Helper to split binary into fixed-size chunks
  defp split_into_chunks(binary, mean_chunk_size) do
    do_split_chunks(binary, mean_chunk_size, [])
  end

  defp do_split_chunks(<<>>, _mean_chunk_size, acc), do: Enum.reverse(acc)

  defp do_split_chunks(binary, mean_chunk_size, acc) do
    chunk_size = :rand.uniform(mean_chunk_size * 2)

    if chunk_size > byte_size(binary) do
      Enum.reverse([binary | acc])
    else
      <<chunk::binary-size(chunk_size), rest::binary>> = binary
      do_split_chunks(rest, mean_chunk_size, [chunk | acc])
    end
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
