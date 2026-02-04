defmodule Vdr.RedisStream.Parser do
  @moduledoc """
  Redis replication stream parser implemented in Rust.

  This module provides a streaming parser for Redis replication protocol.
  (except for few greeting commands)
  The parser handles RDB snapshot transfer and command subsequent online command streaming.

  The parser main states are:
  - WaitingRdb: Initial state, waiting for RDB data
  - ReadingRdb: Parsing RDB snapshot
  - Streaming: Processing command stream after RDB

  This parser is designed to be used internally by Vdr.RedisStream.Replica
  """

  alias Vdr.RedisStream.CommandParser

  @doc """
  Create a new streaming replica parser.

  ## Options

    * `:rdb` - Boolean, default `true`. If `false`, the parser starts in streaming mode
      without expecting RDB data. Use `rdb: false` for partial resync scenarios where
      no RDB snapshot will be transferred.

  ## Returns

  A parser resource that can be used with `data/2`.
  """
  @spec create(keyword()) :: reference()
  def create(opts \\ []) do
    # Extract rdb option (default: true)
    rdb = Keyword.get(opts, :rdb, true)

    # skip_rdb is the inverse of rdb
    skip_rdb = not rdb

    Vdr.RedisStream.Nif.do_replica_create(skip_rdb)
  end

  @typedoc """
  Flags returned from the parser along with commands.

  - `:ping` - `true` if a PING command was encountered during parsing
  - `:replconf_getack` - `true` if a REPLCONF GETACK command was encountered during parsing
  """
  @type flags :: %{ping: boolean(), replconf_getack: boolean()}

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

    * `{:ok, commands, new_parser, flags}` - Successfully processed chunk, returns parsed commands (may be empty)
    * `{:finished, commands}` - Parser finished (connection closed), returns final commands
    * `{:error, reason}` - Parsing failed

  Commands are tuples: `{db, command_tuple, raw_command, affected_keys}` where:
  - `db` is the database number
  - `command_tuple` is a parsed command tuple (e.g., `{:set, key, value}`)
  - `raw_command` is the raw command tuple `{:generic, args}` for logging/debugging
  - `affected_keys` is a list of keys affected by this command

  The flags map contains:
  - `:ping` - `true` if a PING command was encountered during this chunk processing
  - `:replconf_getack` - `true` if a REPLCONF GETACK command was encountered during this chunk processing

  Note: PING and REPLCONF commands are not returned as commands - they are signaled via flags only.
  """
  @spec data(reference(), binary()) ::
          {:ok, list(), reference(), flags()} | {:finished, list()} | {:error, term()}
  def data(parser, chunk) when is_reference(parser) and is_binary(chunk) do
    case Vdr.RedisStream.Nif.replica_data(parser, chunk) do
      {:finished, raw_commands} when is_list(raw_commands) ->
        # Parser finished, convert commands
        commands = convert_commands(raw_commands)
        {:finished, commands}

      {:ok, raw_commands, new_parser, flags} ->
        # More data needed, convert commands
        commands = convert_commands(raw_commands)
        {:ok, commands, new_parser, flags}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp convert_commands(raw_commands) do
    Enum.map(raw_commands, &convert_command/1)
  end

  defp convert_command({db, name, args})
       when is_integer(db) and is_binary(name) and is_list(args) do
    # Delegate to CommandParser for parsing
    {:ok, command, affected_keys} = CommandParser.parse([name | args])

    # Always create the raw generic command tuple from original args
    raw_command = [name | args]

    {db, command, raw_command, affected_keys}
  end
end
