defmodule Vdr.RedisStream.Parser do
  @moduledoc """
  Redis replication stream parser implemented in Rust.

  This module provides a streaming parser for Redis replication protocol
  that handles RDB snapshot transfer and command streaming.

  The parser manages state transitions:
  - WaitingRdb: Initial state, waiting for RDB data
  - ReadingRdb: Parsing RDB snapshot
  - Streaming: Processing command stream after RDB

  ## Example - Basic Usage

      alias Vdr.RedisStream.Command

      # Create parser
      parser = Vdr.RedisStream.Parser.create()

      # Feed data chunks from replication stream
      case Vdr.RedisStream.Parser.data(parser, chunk1) do
        {:ok, commands, parser} ->
          # Process commands from RDB or stream
          Enum.each(commands, fn {db, command, raw_command} ->
            IO.inspect({db, command, raw_command})
          end)

          # Continue feeding more data
          Vdr.RedisStream.Parser.data(parser, chunk2)

        {:ok, commands} ->
          # Parser finished (connection closed)
          process_final_commands(commands)

        {:error, reason} ->
          IO.puts("Error: \#{inspect(reason)}")
      end

  ## Example - Integration with Replica

      # This parser is designed to be used internally by Vdr.RedisStream.Replica
      # For normal use cases, use Vdr.RedisStream.Replica instead.
  """

  alias Vdr.RedisStream.Command, as: RedisCommand
  alias Vdr.RedisStream.CommandParser

  @doc """
  Create a new streaming replica parser.

  ## Options

    * `:rdb` - Boolean, default `true`. If `false`, the parser starts in streaming mode
      without expecting RDB data. Use `rdb: false` for partial resync scenarios where
      no RDB snapshot will be transferred.

  ## Returns

  A parser resource that can be used with `data/2`.

  ## Examples

      # Standard mode - expects RDB followed by command stream
      parser = Vdr.RedisStream.Parser.create()
      {:ok, commands, parser} = Vdr.RedisStream.Parser.data(parser, chunk)

      # Streaming mode - no RDB expected (for partial resync)
      parser = Vdr.RedisStream.Parser.create(rdb: false)
      {:ok, commands, parser} = Vdr.RedisStream.Parser.data(parser, chunk)
  """
  @spec create(keyword()) :: reference()
  def create(opts \\ []) do
    # Extract rdb option (default: true)
    rdb = Keyword.get(opts, :rdb, true)

    # skip_rdb is the inverse of rdb
    skip_rdb = not rdb

    Vdr.RedisStream.Nif.do_replica_create(skip_rdb)
  end

  @doc """
  Feed a chunk of binary data to the replica parser.

  The parser will process the data according to its current state:
  - In WaitingRdb state: waits for RDB bulk string header
  - In ReadingRdb state: parses RDB snapshot and returns commands
  - In Streaming state: parses RESP commands from the stream

  ## Parameters

    * `parser` - Parser resource from `create/0` or previous `data/2` call
    * `chunk` - Binary chunk of replication data

  ## Returns

    * `{:ok, commands}` - Parser finished (connection closed), returns final commands
    * `{:ok, commands, new_parser}` - Successfully processed chunk, returns parsed commands (may be empty)
    * `{:error, reason}` - Parsing failed

  Commands are tuples: `{db, command_struct, raw_command}` where:
  - `db` is the database number
  - `command_struct` is a parsed `Vdr.RedisStream.Command.*` struct
  - `raw_command` is the raw `Vdr.RedisStream.Command.Generic` representation

  ## Example

      parser = Vdr.RedisStream.Parser.create()
      case Vdr.RedisStream.Parser.data(parser, chunk) do
        {:ok, commands, parser} ->
          # More data expected
          process_commands(commands)
          # Continue with next chunk...

        {:ok, commands} ->
          # Finished
          process_final_commands(commands)

        {:error, reason} ->
          handle_error(reason)
      end
  """
  @spec data(reference(), binary()) ::
          {:ok, list()} | {:ok, list(), reference()} | {:error, term()}
  def data(parser, chunk) when is_reference(parser) and is_binary(chunk) do
    case Vdr.RedisStream.Nif.replica_data(parser, chunk) do
      {:ok, raw_commands} when is_list(raw_commands) ->
        # Parser finished, convert commands
        commands = convert_commands(raw_commands)
        {:ok, commands}

      {:ok, raw_commands, new_parser} ->
        # More data needed, convert commands
        commands = convert_commands(raw_commands)
        {:ok, commands, new_parser}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Convert raw Rust commands to Elixir Command structs
  defp convert_commands(raw_commands) do
    Enum.map(raw_commands, &convert_command/1)
  end

  defp convert_command({db, name, args})
       when is_integer(db) and is_binary(name) and is_list(args) do
    # Delegate to CommandParser for parsing
    {:ok, command} = CommandParser.parse([name | args])

    # Always create the raw generic command from original args
    raw_command = %RedisCommand.Generic{args: [name | args]}

    {db, command, raw_command}
  end
end
