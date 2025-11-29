defmodule Veidrodelis.RedisStream.CommandParser do
  @moduledoc """
  Parses Redis replication stream commands (as RESP arrays) into Command structs.

  This parser is specifically designed for Redis replication streams and handles
  all commands that can appear during replication when only strings, sets, hashes,
  zsets, and lists are used.
  """

  alias Veidrodelis.Command

  @doc """
  Parse a Redis command represented as a list of binary arguments into a Command struct.

  Returns `{:ok, command}` for all commands. Unknown commands are wrapped in a `Generic` struct.

  ## Examples

      iex> parse(["SET", "key", "value"])
      {:ok, %Command.Set{key: "key", value: "value"}}

      iex> parse(["SADD", "myset", "m1", "m2"])
      {:ok, %Command.SAdd{key: "myset", members: ["m1", "m2"]}}

      iex> parse(["UNKNOWN", "arg"])
      {:ok, %Command.Generic{args: ["UNKNOWN", "arg"]}}
  """
  @spec parse([binary()]) :: {:ok, Command.t()}
  def parse(["SET", key, value]), do: {:ok, %Command.Set{key: key, value: value}}

  def parse(["MSET" | args]) do
    pairs = parse_pairs(args)
    {:ok, %Command.MSet{pairs: pairs}}
  end

  def parse(["APPEND", key, value]), do: {:ok, %Command.Append{key: key, value: value}}

  def parse(["SETRANGE", key, offset, value]) do
    {:ok, %Command.SetRange{key: key, offset: String.to_integer(offset), value: value}}
  end

  def parse(["SETBIT", key, offset, value]) do
    bit_value = String.to_integer(value)
    {:ok, %Command.SetBit{key: key, offset: String.to_integer(offset), value: bit_value}}
  end

  # List commands
  def parse(["LPUSH", key | values]), do: {:ok, %Command.LPush{key: key, values: values}}
  def parse(["RPUSH", key | values]), do: {:ok, %Command.RPush{key: key, values: values}}
  def parse(["LPUSHX", key | values]), do: {:ok, %Command.LPushX{key: key, values: values}}
  def parse(["RPUSHX", key | values]), do: {:ok, %Command.RPushX{key: key, values: values}}
  def parse(["LPOP", key]), do: {:ok, %Command.LPop{key: key}}
  def parse(["RPOP", key]), do: {:ok, %Command.RPop{key: key}}

  def parse(["LREM", key, count, value]) do
    {:ok, %Command.LRem{key: key, count: String.to_integer(count), value: value}}
  end

  def parse(["LTRIM", key, start, stop]) do
    {:ok,
     %Command.LTrim{
       key: key,
       start: String.to_integer(start),
       stop: String.to_integer(stop)
     }}
  end

  def parse(["LSET", key, index, value]) do
    {:ok, %Command.LSet{key: key, index: String.to_integer(index), value: value}}
  end

  def parse(["LINSERT", key, before_after, pivot, element]) do
    ba =
      case String.upcase(before_after) do
        "BEFORE" -> :before
        "AFTER" -> :after
      end

    {:ok, %Command.LInsert{key: key, before_after: ba, pivot: pivot, element: element}}
  end

  def parse(["RPOPLPUSH", source, destination]) do
    {:ok, %Command.RPopLPush{source: source, destination: destination}}
  end

  # Set commands
  def parse(["SADD", key | members]), do: {:ok, %Command.SAdd{key: key, members: members}}
  def parse(["SREM", key | members]), do: {:ok, %Command.SRem{key: key, members: members}}

  def parse(["SMOVE", source, destination, member]) do
    {:ok, %Command.SMove{source: source, destination: destination, member: member}}
  end

  def parse(["SINTERSTORE", destination | keys]) do
    {:ok, %Command.SInterStore{destination: destination, keys: keys}}
  end

  def parse(["SUNIONSTORE", destination | keys]) do
    {:ok, %Command.SUnionStore{destination: destination, keys: keys}}
  end

  def parse(["SDIFFSTORE", destination | keys]) do
    {:ok, %Command.SDiffStore{destination: destination, keys: keys}}
  end

  # Sorted set commands
  def parse(["ZADD", key | args]) do
    members = parse_zadd_args(args)
    {:ok, %Command.ZAdd{key: key, members: members}}
  end

  def parse(["ZREM", key | members]), do: {:ok, %Command.ZRem{key: key, members: members}}

  def parse(["ZPOPMAX", key]) do
    {:ok, %Command.ZPopMax{key: key, count: 1}}
  end

  def parse(["ZPOPMAX", key, count]) do
    {:ok, %Command.ZPopMax{key: key, count: String.to_integer(count)}}
  end

  def parse(["ZPOPMIN", key]) do
    {:ok, %Command.ZPopMin{key: key, count: 1}}
  end

  def parse(["ZPOPMIN", key, count]) do
    {:ok, %Command.ZPopMin{key: key, count: String.to_integer(count)}}
  end

  def parse(["ZREMRANGEBYRANK", key, start, stop]) do
    {:ok,
     %Command.ZRemRangeByRank{
       key: key,
       start: String.to_integer(start),
       stop: String.to_integer(stop)
     }}
  end

  def parse(["ZREMRANGEBYSCORE", key, min, max]) do
    {:ok, %Command.ZRemRangeByScore{key: key, min: min, max: max}}
  end

  def parse(["ZREMRANGEBYLEX", key, min, max]) do
    {:ok, %Command.ZRemRangeByLex{key: key, min: min, max: max}}
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
    {:ok, %Command.HSet{key: key, fields: fields}}
  end

  def parse(["HDEL", key | fields]), do: {:ok, %Command.HDel{key: key, fields: fields}}

  # Generic key commands
  def parse(["DEL" | keys]), do: {:ok, %Command.Del{keys: keys}}

  def parse(["RENAME", key, newkey]) do
    {:ok, %Command.Rename{key: key, newkey: newkey}}
  end

  def parse(["RENAMENX", key, newkey]) do
    {:ok, %Command.RenameNX{key: key, newkey: newkey}}
  end

  def parse(["MOVE", key, db]) do
    {:ok, %Command.Move{key: key, db: String.to_integer(db)}}
  end

  def parse(["PEXPIREAT", key, timestamp_ms]) do
    {:ok, %Command.PExpireAt{key: key, timestamp_ms: String.to_integer(timestamp_ms)}}
  end

  # Unknown command - wrap in Generic
  def parse(args), do: {:ok, %Command.Generic{args: args}}

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
          %Command.ZUnionStore{
            destination: destination,
            keys: keys,
            weights: weights,
            aggregate: aggregate
          }

        :inter ->
          %Command.ZInterStore{
            destination: destination,
            keys: keys,
            weights: weights,
            aggregate: aggregate
          }
      end

    {:ok, command}
  end
end
