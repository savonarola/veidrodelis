defmodule Vdr.RedisStream.RDB do
  @moduledoc false

  # This module is not actually used by the production code.
  # It provides bindings to the Rust RDB parser used internally by the replica parser.
  #
  # We use these bindings to test the RDB parser via a bit more comfortable ExUnit tests.

  alias Vdr.RedisStream.CommandParser

  def create() do
    Vdr.RedisStream.Nif.rdb_create()
  end

  @spec data(reference(), binary()) ::
          {:ok, list()} | {:ok, list(), reference()} | {:error, term()}
  def data(parser, chunk) when is_reference(parser) and is_binary(chunk) do
    case Vdr.RedisStream.Nif.rdb_data(parser, chunk) do
      {:ok, raw_commands} when is_list(raw_commands) ->
        commands = convert_commands(raw_commands)
        {:ok, commands}

      {:ok, raw_commands, new_parser} ->
        commands = convert_commands(raw_commands)
        {:ok, commands, new_parser}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp convert_commands(raw_commands) do
    Enum.map(raw_commands, &convert_command/1)
  end

  defp convert_command({db, name, args})
       when is_integer(db) and is_binary(name) and is_list(args) do
    {:ok, command, _affected_keys} = CommandParser.parse([name | args])
    {db, command}
  end
end
