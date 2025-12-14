defmodule Vdr.RDB do
  @moduledoc """
  Redis RDB (Redis Database) file parser implemented in Rust.

  This module provides a streaming parser for Redis RDB files that returns
  Redis command structs representing the data in the RDB file.

  ## Example - Basic Usage

      alias Vdr.Command

      # Create parser
      parser = Vdr.RDB.create()

      # Read RDB file
      {:ok, rdb_binary} = File.read("dump.rdb")

      # Feed data and get commands
      case Vdr.RDB.data(parser, rdb_binary) do
        {:ok, commands} ->
          # Parsing complete
          Enum.each(commands, fn
            {_db, %Command.Set{key: k, value: v}} ->
              IO.puts("SET key=value")

            {_db, %Command.RPush{}} ->
              IO.puts("RPUSH command")

            {_db, %Command.SAdd{}} ->
              IO.puts("SADD command")

            {_db, %Command.ZAdd{}} ->
              IO.puts("ZADD command")

            {_db, %Command.HSet{}} ->
              IO.puts("HSET command")

            {_db, %Command.PExpireAt{}} ->
              IO.puts("PEXPIREAT command")
          end)

        {:ok, commands, parser} ->
          # More data needed - partial parsing
          process_commands(commands)
          # Feed more data...

        {:error, reason} ->
          IO.puts("Error: \#{inspect(reason)}")
      end

  ## Example - Streaming/Chunked Parsing

  The parser supports streaming/chunked parsing, which is useful for processing
  large RDB files or reading from network streams:

      # Create parser
      parser = Vdr.RDB.create()

      # Feed data in chunks (any size supported)
      {:ok, commands1, parser} = Vdr.RDB.data(parser, chunk1)
      {:ok, commands2, parser} = Vdr.RDB.data(parser, chunk2)
      {:ok, commands3} = Vdr.RDB.data(parser, chunk3)  # Final chunk (EOF)

      # Process all commands
      all_commands = commands1 ++ commands2 ++ commands3
      Enum.each(all_commands, &process_command/1)
  """

  alias Vdr.Command

  @doc """
  Create a new streaming RDB parser.

  ## Returns

  A parser resource that can be used with `data/2`.

  ## Example

      parser = Vdr.RDB.create()
      {:ok, commands, parser} = Vdr.RDB.data(parser, chunk1)
  """
  @spec create() :: reference()
  def create() do
    Vdr.RedisParser.create()
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

      parser = Vdr.RDB.create()
      case Vdr.RDB.data(parser, chunk) do
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
    case Vdr.RedisParser.data(parser, chunk) do
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

  defp convert_command({db, name, args}) when is_integer(db) and is_binary(name) and is_list(args) do
    command = case name do
      "SET" ->
        [key, value] = args
        %Command.Set{key: key, value: value}

      "RPUSH" ->
        [key | values] = args
        %Command.RPush{key: key, values: values}

      "SADD" ->
        [key | members] = args
        %Command.SAdd{key: key, members: members}

      "ZADD" ->
        [key | score_member_pairs] = args
        members = parse_zadd_args(score_member_pairs, [])
        %Command.ZAdd{key: key, members: members}

      "HSET" ->
        [key | field_value_pairs] = args
        fields = parse_hset_args(field_value_pairs, [])
        %Command.HSet{key: key, fields: fields}

      "PEXPIREAT" ->
        [key, timestamp_str] = args
        timestamp_ms = String.to_integer(timestamp_str)
        %Command.PExpireAt{key: key, timestamp_ms: timestamp_ms}

      _ ->
        nil
    end

    {db, command}
  end

  # Parse ZADD arguments: [score, member, score, member, ...]
  defp parse_zadd_args([], acc), do: Enum.reverse(acc)
  defp parse_zadd_args([score_bin, member | rest], acc) do
    score = parse_float(score_bin)
    parse_zadd_args(rest, [{score, member} | acc])
  end

  # Parse HSET arguments: [field, value, field, value, ...]
  defp parse_hset_args([], acc), do: Enum.reverse(acc)
  defp parse_hset_args([field, value | rest], acc) do
    parse_hset_args(rest, [{field, value} | acc])
  end

  defp parse_float(bin) when is_binary(bin) do
    case Float.parse(bin) do
      {float, _} -> float
      :error ->
        # Try as integer
        case Integer.parse(bin) do
          {int, _} -> int * 1.0
          :error -> 0.0
        end
    end
  end
end
