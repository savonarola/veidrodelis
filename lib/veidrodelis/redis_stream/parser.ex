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
    # Always create the raw generic command from original args
    raw_command = %RedisCommand.Generic{args: [name | args]}

    command =
      case name do
        # String commands
        "SET" when length(args) >= 2 ->
          [key, value | _rest] = args
          %RedisCommand.Set{key: key, value: value}

        "MSET" when length(args) >= 2 ->
          pairs = parse_pairs(args, [])
          %RedisCommand.MSet{pairs: pairs}

        "APPEND" when length(args) == 2 ->
          [key, value] = args
          %RedisCommand.Append{key: key, value: value}

        "SETRANGE" when length(args) == 3 ->
          [key, offset_str, value] = args
          offset = String.to_integer(offset_str)
          %RedisCommand.SetRange{key: key, offset: offset, value: value}

        "SETBIT" when length(args) == 3 ->
          [key, offset_str, value_str] = args
          offset = String.to_integer(offset_str)
          value = String.to_integer(value_str)
          %RedisCommand.SetBit{key: key, offset: offset, value: value}

        # List commands
        "RPUSH" ->
          [key | values] = args
          %RedisCommand.RPush{key: key, values: values}

        "LPUSH" ->
          [key | values] = args
          %RedisCommand.LPush{key: key, values: values}

        "LPUSHX" ->
          [key | values] = args
          %RedisCommand.LPushX{key: key, values: values}

        "RPUSHX" ->
          [key | values] = args
          %RedisCommand.RPushX{key: key, values: values}

        "LPOP" when length(args) >= 1 ->
          [key | _rest] = args
          %RedisCommand.LPop{key: key}

        "RPOP" when length(args) >= 1 ->
          [key | _rest] = args
          %RedisCommand.RPop{key: key}

        "LREM" when length(args) == 3 ->
          [key, count_str, value] = args
          count = String.to_integer(count_str)
          %RedisCommand.LRem{key: key, count: count, value: value}

        "LTRIM" when length(args) == 3 ->
          [key, start_str, stop_str] = args
          start = String.to_integer(start_str)
          stop = String.to_integer(stop_str)
          %RedisCommand.LTrim{key: key, start: start, stop: stop}

        "LSET" when length(args) == 3 ->
          [key, index_str, value] = args
          index = String.to_integer(index_str)
          %RedisCommand.LSet{key: key, index: index, value: value}

        "LINSERT" when length(args) == 4 ->
          [key, before_after_str, pivot, element] = args
          before_after = if String.upcase(before_after_str) == "BEFORE", do: :before, else: :after

          %RedisCommand.LInsert{
            key: key,
            before_after: before_after,
            pivot: pivot,
            element: element
          }

        "RPOPLPUSH" when length(args) == 2 ->
          [source, destination] = args
          %RedisCommand.RPopLPush{source: source, destination: destination}

        # Set commands
        "SADD" ->
          [key | members] = args
          %RedisCommand.SAdd{key: key, members: members}

        "SREM" ->
          [key | members] = args
          %RedisCommand.SRem{key: key, members: members}

        "SMOVE" when length(args) == 3 ->
          [source, destination, member] = args
          %RedisCommand.SMove{source: source, destination: destination, member: member}

        "SINTERSTORE" when length(args) >= 2 ->
          [destination, _numkeys | keys] = args
          %RedisCommand.SInterStore{destination: destination, keys: keys}

        "SUNIONSTORE" when length(args) >= 2 ->
          [destination, _numkeys | keys] = args
          %RedisCommand.SUnionStore{destination: destination, keys: keys}

        "SDIFFSTORE" when length(args) >= 2 ->
          [destination, _numkeys | keys] = args
          %RedisCommand.SDiffStore{destination: destination, keys: keys}

        # Sorted set commands
        "ZADD" ->
          [key | rest] = args
          # Parse ZADD options and score-member pairs
          {options, score_member_pairs} = parse_zadd_options(rest, [])
          members = parse_zadd_args(score_member_pairs, [])
          %RedisCommand.ZAdd{key: key, members: members, options: options}

        "ZUNIONSTORE" when length(args) >= 2 ->
          parse_zunionstore(args)

        "ZINTERSTORE" when length(args) >= 2 ->
          parse_zinterstore(args)

        "ZREM" ->
          [key | members] = args
          %RedisCommand.ZRem{key: key, members: members}

        "ZPOPMAX" ->
          [key | rest] = args
          count = if rest == [], do: 1, else: String.to_integer(List.first(rest))
          %RedisCommand.ZPopMax{key: key, count: count}

        "ZPOPMIN" ->
          [key | rest] = args
          count = if rest == [], do: 1, else: String.to_integer(List.first(rest))
          %RedisCommand.ZPopMin{key: key, count: count}

        "ZREMRANGEBYRANK" when length(args) == 3 ->
          [key, start_str, stop_str] = args
          start = String.to_integer(start_str)
          stop = String.to_integer(stop_str)
          %RedisCommand.ZRemRangeByRank{key: key, start: start, stop: stop}

        "ZREMRANGEBYSCORE" when length(args) == 3 ->
          [key, min, max] = args
          %RedisCommand.ZRemRangeByScore{key: key, min: min, max: max}

        "ZREMRANGEBYLEX" when length(args) == 3 ->
          [key, min, max] = args
          %RedisCommand.ZRemRangeByLex{key: key, min: min, max: max}

        # Hash commands
        "HSET" ->
          [key | field_value_pairs] = args
          fields = parse_hset_args(field_value_pairs, [])
          %RedisCommand.HSet{key: key, fields: fields}

        "HDEL" ->
          [key | fields] = args
          %RedisCommand.HDel{key: key, fields: fields}

        # Key management
        "DEL" when length(args) >= 1 ->
          %RedisCommand.Del{keys: args}

        "RENAME" when length(args) == 2 ->
          [key, newkey] = args
          %RedisCommand.Rename{key: key, newkey: newkey}

        "RENAMENX" when length(args) == 2 ->
          [key, newkey] = args
          %RedisCommand.RenameNX{key: key, newkey: newkey}

        "MOVE" when length(args) == 2 ->
          [key, db_str] = args
          db = String.to_integer(db_str)
          %RedisCommand.Move{key: key, db: db}

        # Expiration
        "PEXPIREAT" when length(args) == 2 ->
          [key, timestamp_str] = args
          timestamp_ms = String.to_integer(timestamp_str)
          %RedisCommand.PExpireAt{key: key, timestamp_ms: timestamp_ms}

        _ ->
          # Return raw generic command for unknown or malformed commands
          raw_command
      end

    {db, command, raw_command}
  end

  # Parse MSET arguments: [key, value, key, value, ...]
  defp parse_pairs([], acc), do: Enum.reverse(acc)

  defp parse_pairs([key, value | rest], acc) do
    parse_pairs(rest, [{key, value} | acc])
  end

  # Parse ZUNIONSTORE/ZINTERSTORE args: destination numkeys key1 key2 ... [WEIGHTS w1 w2 ...] [AGGREGATE SUM|MIN|MAX]
  defp parse_zunionstore([destination, numkeys_str | rest]) do
    numkeys = String.to_integer(numkeys_str)
    {keys, rest} = Enum.split(rest, numkeys)
    {weights, aggregate} = parse_zstore_options(rest)

    %RedisCommand.ZUnionStore{
      destination: destination,
      keys: keys,
      weights: weights,
      aggregate: aggregate
    }
  end

  defp parse_zinterstore([destination, numkeys_str | rest]) do
    numkeys = String.to_integer(numkeys_str)
    {keys, rest} = Enum.split(rest, numkeys)
    {weights, aggregate} = parse_zstore_options(rest)

    %RedisCommand.ZInterStore{
      destination: destination,
      keys: keys,
      weights: weights,
      aggregate: aggregate
    }
  end

  defp parse_zstore_options(args) do
    parse_zstore_options(args, nil, nil)
  end

  defp parse_zstore_options([], weights, aggregate), do: {weights, aggregate}

  defp parse_zstore_options(["WEIGHTS" | rest], _weights, aggregate) do
    {weight_strs, rest} = Enum.split_while(rest, fn arg -> arg not in ["AGGREGATE"] end)
    weights = Enum.map(weight_strs, &parse_float/1)
    parse_zstore_options(rest, weights, aggregate)
  end

  defp parse_zstore_options(["AGGREGATE", agg_str | rest], weights, _aggregate) do
    aggregate =
      case String.upcase(agg_str) do
        "SUM" -> :sum
        "MIN" -> :min
        "MAX" -> :max
        _ -> :sum
      end

    parse_zstore_options(rest, weights, aggregate)
  end

  defp parse_zstore_options([_ | rest], weights, aggregate) do
    parse_zstore_options(rest, weights, aggregate)
  end

  # Parse ZADD options, separating them from score-member pairs
  # Returns {options_list, remaining_args}
  defp parse_zadd_options([], acc_options), do: {Enum.reverse(acc_options), []}

  defp parse_zadd_options([arg | rest], acc_options) do
    case String.upcase(arg) do
      "NX" -> parse_zadd_options(rest, [:nx | acc_options])
      "XX" -> parse_zadd_options(rest, [:xx | acc_options])
      "GT" -> parse_zadd_options(rest, [:gt | acc_options])
      "LT" -> parse_zadd_options(rest, [:lt | acc_options])
      "CH" -> parse_zadd_options(rest, [:ch | acc_options])
      "INCR" -> parse_zadd_options(rest, [:incr | acc_options])
      _ -> {Enum.reverse(acc_options), [arg | rest]}  # Found score-member pairs
    end
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
