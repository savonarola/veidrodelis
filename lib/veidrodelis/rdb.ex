defmodule Vdr.RDB do
  @moduledoc false

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
    Vdr.RedisNif.rdb_create()
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
    case Vdr.RedisNif.rdb_data(parser, chunk) do
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
    command =
      case name do
        # String commands
        "SET" when length(args) >= 2 ->
          [key, value | _rest] = args
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
          [key | [expire_ms]] = args
          %Command.PExpireAt{key: key, timestamp_ms: expire_ms}
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
      {float, _} ->
        float

      :error ->
        # Try as integer
        case Integer.parse(bin) do
          {int, _} -> int * 1.0
          :error -> 0.0
        end
    end
  end
end
