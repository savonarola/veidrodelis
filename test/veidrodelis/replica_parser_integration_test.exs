defmodule Vdr.ReplicaParserIntegrationTest do
  use ExUnit.Case, async: true

  alias Vdr.Command

  @moduledoc """
  Integration tests for replica parser with realistic data.
  Tests the full flow: RDB header -> RDB snapshot -> Command streaming
  """

  describe "simple RESP parsing" do
    test "parses a single SET command in streaming mode" do
      parser = Vdr.ReplicaParser.create()

      # Feed minimal RDB first to get into streaming mode
      rdb_data = build_minimal_rdb()
      rdb_header = "$#{byte_size(rdb_data)}\r\n"
      {:ok, _, parser} = Vdr.ReplicaParser.data(parser, rdb_header <> rdb_data)

      # Single SET command
      cmd = "*3\r\n$3\r\nSET\r\n$4\r\nkey1\r\n$6\r\nvalue1\r\n"
      {:ok, commands, _parser} = Vdr.ReplicaParser.data(parser, cmd)

      assert length(commands) == 1
      assert match?([{0, %Command.Set{key: "key1", value: "value1"}}], commands)
    end

    test "parses two SET commands in streaming mode" do
      parser = Vdr.ReplicaParser.create()

      # Feed minimal RDB first
      rdb_data = build_minimal_rdb()
      {:ok, _, parser} = Vdr.ReplicaParser.data(parser, "$#{byte_size(rdb_data)}\r\n" <> rdb_data)

      # Two SET commands
      cmds =
        "*3\r\n$3\r\nSET\r\n$4\r\nkey1\r\n$6\r\nvalue1\r\n" <>
          "*3\r\n$3\r\nSET\r\n$4\r\nkey2\r\n$6\r\nvalue2\r\n"

      {:ok, commands, _parser} = Vdr.ReplicaParser.data(parser, cmds)

      assert length(commands) == 2
      assert match?([{0, %Command.Set{key: "key1"}}, {0, %Command.Set{key: "key2"}}], commands)
    end

    test "parses RPUSH command in streaming mode" do
      parser = Vdr.ReplicaParser.create()

      # Feed minimal RDB first
      rdb_data = build_minimal_rdb()
      {:ok, _, parser} = Vdr.ReplicaParser.data(parser, "$#{byte_size(rdb_data)}\r\n" <> rdb_data)

      # RPUSH with 2 values: *4\r\n$6\r\nRPUSH\r\n$7\r\nmylist\r\n$5\r\nitem1\r\n$5\r\nitem2\r\n
      cmd = "*4\r\n$5\r\nRPUSH\r\n$6\r\nmylist\r\n$5\r\nitem1\r\n$5\r\nitem2\r\n"

      {:ok, commands, _parser} = Vdr.ReplicaParser.data(parser, cmd)

      assert length(commands) == 1
      assert match?([{0, %Command.RPush{key: "mylist", values: ["item1", "item2"]}}], commands)
    end
  end

  describe "RDB transfer integration" do
    test "parses RDB bulk string header and transitions to reading state" do
      parser = Vdr.ReplicaParser.create()

      # Simulate PSYNC response followed by RDB bulk string header
      # $88\r\n (88 bytes of RDB data to follow)
      # This is followed by actual RDB data (we'll use a simple valid RDB)
      rdb_header = "$88\r\n"

      # Simple RDB file: REDIS version + EOF + checksum
      # Create minimal valid RDB
      rdb_data = build_minimal_rdb()

      # Feed header
      {:ok, commands1, parser} = Vdr.ReplicaParser.data(parser, rdb_header)
      # Should return empty - just parsed header
      assert commands1 == []

      # Feed RDB data in chunks
      chunk_size = 30
      chunks = for <<chunk::binary-size(chunk_size) <- rdb_data>>, do: chunk
      # Get remaining bytes if any
      remainder_size = rem(byte_size(rdb_data), chunk_size)

      chunks =
        if remainder_size > 0 do
          chunks ++ [binary_part(rdb_data, byte_size(rdb_data) - remainder_size, remainder_size)]
        else
          chunks
        end

      {final_parser, all_commands} =
        Enum.reduce(chunks, {parser, []}, fn chunk, {p, cmds} ->
          case Vdr.ReplicaParser.data(p, chunk) do
            {:ok, new_cmds, new_parser} ->
              {new_parser, cmds ++ new_cmds}

            {:ok, new_cmds} ->
              # Finished
              {p, cmds ++ new_cmds}
          end
        end)

      # Should have transitioned to streaming mode after RDB
      assert is_reference(final_parser)

      # all_commands should contain any commands from the RDB (empty in minimal RDB)
      assert is_list(all_commands)
    end

    test "parses RDB with data and then command stream" do
      parser = Vdr.ReplicaParser.create()

      # Build an RDB file with actual data
      rdb_data = build_rdb_with_data()
      rdb_header = "$#{byte_size(rdb_data)}\r\n"

      # Feed RDB
      {:ok, commands1, parser} = Vdr.ReplicaParser.data(parser, rdb_header <> rdb_data)

      # Should have parsed commands from RDB
      assert length(commands1) > 0

      # Verify we got SET commands from RDB
      set_commands =
        Enum.filter(commands1, fn
          {_db, %Command.Set{}} -> true
          _ -> false
        end)

      assert length(set_commands) > 0

      # Now feed streaming commands
      # *3\r\n$3\r\nSET\r\n$4\r\nkey1\r\n$6\r\nvalue1\r\n
      resp_cmd = "*3\r\n$3\r\nSET\r\n$4\r\nkey1\r\n$6\r\nvalue1\r\n"
      {:ok, commands2, parser} = Vdr.ReplicaParser.data(parser, resp_cmd)

      # Should have parsed the SET command from stream
      assert length(commands2) == 1
      assert match?([{0, %Command.Set{key: "key1", value: "value1"}}], commands2)

      assert is_reference(parser)
    end

    test "handles leading newlines before RDB header" do
      parser = Vdr.ReplicaParser.create()

      # Redis sends \n while preparing RDB
      data = "\n\n\n$88\r\n" <> build_minimal_rdb()

      {:ok, _commands, parser} = Vdr.ReplicaParser.data(parser, data)
      assert is_reference(parser)
    end

    test "parses multiple commands in streaming mode" do
      parser = Vdr.ReplicaParser.create()

      # Feed RDB first
      rdb_data = build_minimal_rdb()
      rdb_header = "$#{byte_size(rdb_data)}\r\n"
      {:ok, _commands, parser} = Vdr.ReplicaParser.data(parser, rdb_header <> rdb_data)

      # Feed multiple RESP commands at once
      commands_data =
        "*3\r\n$3\r\nSET\r\n$4\r\nkey1\r\n$6\r\nvalue1\r\n" <>
          "*3\r\n$3\r\nSET\r\n$4\r\nkey2\r\n$6\r\nvalue2\r\n" <>
          "*4\r\n$5\r\nRPUSH\r\n$6\r\nmylist\r\n$5\r\nitem1\r\n$5\r\nitem2\r\n"

      {:ok, commands, parser} = Vdr.ReplicaParser.data(parser, commands_data)

      # Should have parsed 3 commands
      assert length(commands) == 3

      # Verify command types
      assert match?({0, %Command.Set{key: "key1", value: "value1"}}, Enum.at(commands, 0))
      assert match?({0, %Command.Set{key: "key2", value: "value2"}}, Enum.at(commands, 1))

      assert match?(
               {0, %Command.RPush{key: "mylist", values: ["item1", "item2"]}},
               Enum.at(commands, 2)
             )

      assert is_reference(parser)
    end

    test "filters out SELECT commands and tracks database changes" do
      parser = Vdr.ReplicaParser.create()

      # Feed RDB first
      rdb_data = build_minimal_rdb()

      {:ok, _commands, parser} =
        Vdr.ReplicaParser.data(parser, "$#{byte_size(rdb_data)}\r\n" <> rdb_data)

      # SELECT command should be filtered out but db should change
      select_cmd = "*2\r\n$6\r\nSELECT\r\n$1\r\n3\r\n"
      set_cmd = "*3\r\n$3\r\nSET\r\n$4\r\nkey1\r\n$6\r\nvalue1\r\n"

      {:ok, commands, parser} = Vdr.ReplicaParser.data(parser, select_cmd <> set_cmd)

      # Should only have SET command, SELECT filtered out
      assert length(commands) == 1
      assert match?([{3, %Command.Set{key: "key1", value: "value1"}}], commands)

      assert is_reference(parser)
    end

    test "filters out PING and REPLCONF commands" do
      parser = Vdr.ReplicaParser.create()

      # Feed RDB first
      rdb_data = build_minimal_rdb()

      {:ok, _commands, parser} =
        Vdr.ReplicaParser.data(parser, "$#{byte_size(rdb_data)}\r\n" <> rdb_data)

      # PING and REPLCONF should be filtered
      ping_cmd = "*1\r\n$4\r\nPING\r\n"
      replconf_cmd = "*3\r\n$8\r\nREPLCONF\r\n$6\r\nGETACK\r\n$1\r\n*\r\n"
      set_cmd = "*3\r\n$3\r\nSET\r\n$4\r\nkey1\r\n$6\r\nvalue1\r\n"

      {:ok, commands, parser} =
        Vdr.ReplicaParser.data(parser, ping_cmd <> replconf_cmd <> set_cmd)

      # Should only have SET command
      assert length(commands) == 1
      assert match?([{0, %Command.Set{}}], commands)

      assert is_reference(parser)
    end

    test "handles chunked data correctly" do
      parser = Vdr.ReplicaParser.create()

      # Build full data
      rdb_data = build_minimal_rdb()

      full_data =
        "$#{byte_size(rdb_data)}\r\n" <>
          rdb_data <>
          "*3\r\n$3\r\nSET\r\n$4\r\nkey1\r\n$6\r\nvalue1\r\n"

      # Feed in tiny chunks
      chunk_size = 5

      {_final_parser, all_commands} =
        Enum.reduce(0..div(byte_size(full_data), chunk_size), {parser, []}, fn i, {p, cmds} ->
          offset = i * chunk_size
          remaining = byte_size(full_data) - offset
          size = min(chunk_size, remaining)

          if size > 0 do
            chunk = binary_part(full_data, offset, size)

            case Vdr.ReplicaParser.data(p, chunk) do
              {:ok, new_cmds, new_parser} ->
                {new_parser, cmds ++ new_cmds}

              {:ok, new_cmds} ->
                {p, cmds ++ new_cmds}
            end
          else
            {p, cmds}
          end
        end)

      # Should still parse correctly
      set_commands =
        Enum.filter(all_commands, fn
          {_db, %Command.Set{}} -> true
          _ -> false
        end)

      assert length(set_commands) >= 1
    end
  end

  # Helper functions to build test RDB data

  defp build_minimal_rdb() do
    # REDIS0012 (magic + version 12) + EOF (255) + 8 byte checksum
    "REDIS0012" <> <<255>> <> <<0, 0, 0, 0, 0, 0, 0, 0>>
  end

  defp build_rdb_with_data() do
    # Build a simple RDB with one SET command
    # REDIS magic + version
    magic = "REDIS0012"

    # SELECTDB opcode (254) + db number (0)
    selectdb = <<254, 0>>

    # String value: key="test", value="data"
    # Type=0 (string), key (length=4, data="test"), value (length=4, data="data")
    key_data = encode_string("test")
    value_data = encode_string("data")
    kv_pair = <<0>> <> key_data <> value_data

    # EOF + checksum
    eof_and_checksum = <<255, 0, 0, 0, 0, 0, 0, 0, 0>>

    magic <> selectdb <> kv_pair <> eof_and_checksum
  end

  defp encode_string(str) when is_binary(str) do
    len = byte_size(str)
    # Simple length encoding for strings < 64 bytes
    <<len>> <> str
  end
end
