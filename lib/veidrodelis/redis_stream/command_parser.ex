defmodule Vdr.RedisStream.CommandParser do
  @moduledoc """
  Parses Redis replication stream commands (as RESP arrays) into Command structs.

  This parser is specifically designed for Redis replication streams and handles
  all commands that can appear during replication when only strings, sets, hashes,
  zsets, and lists are used.
  """

  alias Vdr.RedisStream.Command, as: RedisCommand

  @doc """
  Parse a Redis command represented as a list of binary arguments into a Command struct.

  Returns `{:ok, command}` for all commands. Unknown commands are wrapped in a `Generic` struct.

  ## Examples

      iex> parse(["SET", "key", "value"])
      {:ok, %RedisCommand.Set{key: "key", value: "value"}}

      iex> parse(["SADD", "myset", "m1", "m2"])
      {:ok, %RedisCommand.SAdd{key: "myset", members: ["m1", "m2"]}}

      iex> parse(["UNKNOWN", "arg"])
      {:ok, %RedisCommand.Generic{args: ["UNKNOWN", "arg"]}}
  """
  @spec parse([binary()]) :: {:ok, RedisCommand.t()}
  def parse(["SET", key, value]), do: {:ok, %RedisCommand.Set{key: key, value: value}}

  def parse(["MSET" | args]) do
    pairs = parse_pairs(args)
    {:ok, %RedisCommand.MSet{pairs: pairs}}
  end

  def parse(["APPEND", key, value]), do: {:ok, %RedisCommand.Append{key: key, value: value}}

  def parse(["SETRANGE", key, offset, value]) do
    {:ok, %RedisCommand.SetRange{key: key, offset: String.to_integer(offset), value: value}}
  end

  def parse(["SETBIT", key, offset, value]) do
    bit_value = String.to_integer(value)
    {:ok, %RedisCommand.SetBit{key: key, offset: String.to_integer(offset), value: bit_value}}
  end

  # List commands
  def parse(["LPUSH", key | values]), do: {:ok, %RedisCommand.LPush{key: key, values: values}}
  def parse(["RPUSH", key | values]), do: {:ok, %RedisCommand.RPush{key: key, values: values}}
  def parse(["LPUSHX", key | values]), do: {:ok, %RedisCommand.LPushX{key: key, values: values}}
  def parse(["RPUSHX", key | values]), do: {:ok, %RedisCommand.RPushX{key: key, values: values}}
  def parse(["LPOP", key]), do: {:ok, %RedisCommand.LPop{key: key}}
  def parse(["RPOP", key]), do: {:ok, %RedisCommand.RPop{key: key}}

  def parse(["LREM", key, count, value]) do
    {:ok, %RedisCommand.LRem{key: key, count: String.to_integer(count), value: value}}
  end

  def parse(["LTRIM", key, start, stop]) do
    {:ok,
     %RedisCommand.LTrim{
       key: key,
       start: String.to_integer(start),
       stop: String.to_integer(stop)
     }}
  end

  def parse(["LSET", key, index, value]) do
    {:ok, %RedisCommand.LSet{key: key, index: String.to_integer(index), value: value}}
  end

  def parse(["LINSERT", key, before_after, pivot, element]) do
    ba =
      case String.upcase(before_after) do
        "BEFORE" -> :before
        "AFTER" -> :after
      end

    {:ok, %RedisCommand.LInsert{key: key, before_after: ba, pivot: pivot, element: element}}
  end

  def parse(["RPOPLPUSH", source, destination]) do
    {:ok, %RedisCommand.RPopLPush{source: source, destination: destination}}
  end

  # Set commands
  def parse(["SADD", key | members]), do: {:ok, %RedisCommand.SAdd{key: key, members: members}}
  def parse(["SREM", key | members]), do: {:ok, %RedisCommand.SRem{key: key, members: members}}

  def parse(["SMOVE", source, destination, member]) do
    {:ok, %RedisCommand.SMove{source: source, destination: destination, member: member}}
  end

  def parse(["SINTERSTORE", destination | keys]) do
    {:ok, %RedisCommand.SInterStore{destination: destination, keys: keys}}
  end

  def parse(["SUNIONSTORE", destination | keys]) do
    {:ok, %RedisCommand.SUnionStore{destination: destination, keys: keys}}
  end

  def parse(["SDIFFSTORE", destination | keys]) do
    {:ok, %RedisCommand.SDiffStore{destination: destination, keys: keys}}
  end

  # Sorted set commands
  def parse(["ZADD", key | args]) do
    members = parse_zadd_args(args)
    {:ok, %RedisCommand.ZAdd{key: key, members: members}}
  end

  def parse(["ZREM", key | members]), do: {:ok, %RedisCommand.ZRem{key: key, members: members}}

  def parse(["ZPOPMAX", key]) do
    {:ok, %RedisCommand.ZPopMax{key: key, count: 1}}
  end

  def parse(["ZPOPMAX", key, count]) do
    {:ok, %RedisCommand.ZPopMax{key: key, count: String.to_integer(count)}}
  end

  def parse(["ZPOPMIN", key]) do
    {:ok, %RedisCommand.ZPopMin{key: key, count: 1}}
  end

  def parse(["ZPOPMIN", key, count]) do
    {:ok, %RedisCommand.ZPopMin{key: key, count: String.to_integer(count)}}
  end

  def parse(["ZREMRANGEBYRANK", key, start, stop]) do
    {:ok,
     %RedisCommand.ZRemRangeByRank{
       key: key,
       start: String.to_integer(start),
       stop: String.to_integer(stop)
     }}
  end

  def parse(["ZREMRANGEBYSCORE", key, min, max]) do
    {:ok, %RedisCommand.ZRemRangeByScore{key: key, min: min, max: max}}
  end

  def parse(["ZREMRANGEBYLEX", key, min, max]) do
    {:ok, %RedisCommand.ZRemRangeByLex{key: key, min: min, max: max}}
  end

  def parse(["ZUNIONSTORE", destination, _numkeys | rest]) do
    # Parse ZUNIONSTORE destination numkeys key [key ...] [WEIGHTS weight [weight ...]] [AGGREGATE SUM|MIN|MAX]
    parse_zstore_command(destination, rest, :union)
  end

  def parse(["ZINTERSTORE", destination, _numkeys | rest]) do
    # Parse ZINTERSTORE destination numkeys key [key ...] [WEIGHTS weight [weight ...]] [AGGREGATE SUM|MIN|MAX]
    parse_zstore_command(destination, rest, :inter)
  end

  # Hash commands
  def parse(["HSET", key | args]) do
    fields = parse_pairs(args)
    {:ok, %RedisCommand.HSet{key: key, fields: fields}}
  end

  def parse(["HDEL", key | fields]), do: {:ok, %RedisCommand.HDel{key: key, fields: fields}}

  # Generic key commands
  def parse(["DEL" | keys]), do: {:ok, %RedisCommand.Del{keys: keys}}

  def parse(["RENAME", key, newkey]) do
    {:ok, %RedisCommand.Rename{key: key, newkey: newkey}}
  end

  def parse(["RENAMENX", key, newkey]) do
    {:ok, %RedisCommand.RenameNX{key: key, newkey: newkey}}
  end

  def parse(["MOVE", key, db]) do
    {:ok, %RedisCommand.Move{key: key, db: String.to_integer(db)}}
  end

  def parse(["PEXPIREAT", key, timestamp_ms]) do
    {:ok, %RedisCommand.PExpireAt{key: key, timestamp_ms: String.to_integer(timestamp_ms)}}
  end

  # Unknown command - wrap in Generic
  def parse(args), do: {:ok, %RedisCommand.Generic{args: args}}

  # Helper functions

  defp parse_pairs([]), do: []
  defp parse_pairs([k, v | rest]), do: [{k, v} | parse_pairs(rest)]

  defp parse_zadd_args([]), do: []

  defp parse_zadd_args([score_str, member | rest]) do
    score = parse_float(score_str)
    [{score, member} | parse_zadd_args(rest)]
  end

  defp parse_float(str) do
    case str do
      "nan" ->
        :nan

      "+inf" ->
        :pos_inf

      "-inf" ->
        :neg_inf

      _ ->
        case Float.parse(str) do
          {float, _} -> float
          :error -> String.to_integer(str) * 1.0
        end
    end
  end

  defp parse_zstore_command(destination, args, type) do
    {keys, rest} = Enum.split_while(args, &(&1 not in ["WEIGHTS", "AGGREGATE"]))

    {weights, rest} =
      case rest do
        ["WEIGHTS" | rest] ->
          {weight_strs, rest} = Enum.split_while(rest, &(&1 != "AGGREGATE"))
          weights = Enum.map(weight_strs, &parse_float/1)
          {weights, rest}

        _ ->
          {nil, rest}
      end

    aggregate =
      case rest do
        ["AGGREGATE", agg_str | _] ->
          case String.upcase(agg_str) do
            "SUM" -> :sum
            "MIN" -> :min
            "MAX" -> :max
          end

        _ ->
          nil
      end

    command =
      case type do
        :union ->
          %RedisCommand.ZUnionStore{
            destination: destination,
            keys: keys,
            weights: weights,
            aggregate: aggregate
          }

        :inter ->
          %RedisCommand.ZInterStore{
            destination: destination,
            keys: keys,
            weights: weights,
            aggregate: aggregate
          }
      end

    {:ok, command}
  end
end
