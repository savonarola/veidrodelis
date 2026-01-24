defmodule Vdr.RedisStream.RDB do
  @moduledoc false

  alias Vdr.RedisStream.CommandParser

  @doc """
  Create a new streaming RDB parser.

  ## Returns

  A parser resource that can be used with `data/2`.

  ## Example

      parser = Vdr.RedisStream.RDB.create()
      {:ok, commands, parser} = Vdr.RedisStream.RDB.data(parser, chunk1)
  """
  @spec create() :: reference()
  def create() do
    Vdr.RedisStream.Nif.rdb_create()
  end

  @doc """
  Feed a chunk of binary data to the parser.

  The parser will accumulate chunks and parse as much as possible,
  returning any commands that were successfully parsed.

  ## Parameters

    * `parser` - Parser resource from `create/0` or previous `data/2` call
    * `chunk` - Binary chunk of RDB data

  ## Returns

    * `{:ok, commands}` - Parsing completed (EOF reached), returns final commands
    * `{:ok, commands, new_parser}` - Successfully processed chunk, returns parsed commands (may be empty)
    * `{:error, reason}` - Parsing failed

  ## Example

      parser = Vdr.RedisStream.RDB.create()
      case Vdr.RedisStream.RDB.data(parser, chunk) do
        {:ok, commands} ->
          # EOF reached
          process_final_commands(commands)

        {:ok, commands, parser} ->
          # More data needed
          process_commands(commands)
          # Continue with next chunk...

        {:error, reason} ->
          handle_error(reason)
      end
  """
  @spec data(reference(), binary()) ::
          {:ok, list()} | {:ok, list(), reference()} | {:error, term()}
  def data(parser, chunk) when is_reference(parser) and is_binary(chunk) do
    case Vdr.RedisStream.Nif.rdb_data(parser, chunk) do
      {:ok, raw_commands} when is_list(raw_commands) ->
        # EOF reached, convert commands
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
    {:ok, command, _affected_keys} = CommandParser.parse([name | args])
    {db, command}
  end
end
