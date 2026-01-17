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
  # SET with options (Redis 8.x replicates INCRBYFLOAT, SETEX, PSETEX as SET with options)
  # SET key value [KEEPTTL | PXAT timestamp]
  def parse(["SET", key, value | options]) when length(options) > 0 do
    # For now, we ignore the options and just use the key-value
    # KEEPTTL means keep existing TTL, PXAT means expire at timestamp
    # Since we don't implement expiration yet, we can ignore these
    {:ok, %RedisCommand.Set{key: key, value: value}}
  end

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

  # Numeric string commands
  def parse(["INCR", key]), do: {:ok, %RedisCommand.Incr{key: key}}
  def parse(["INCRBY", key, increment]), do: {:ok, %RedisCommand.IncrBy{key: key, increment: String.to_integer(increment)}}
  def parse(["DECR", key]), do: {:ok, %RedisCommand.Decr{key: key}}
  def parse(["DECRBY", key, decrement]), do: {:ok, %RedisCommand.DecrBy{key: key, decrement: String.to_integer(decrement)}}

  # Conditional set commands
  def parse(["SETNX", key, value]), do: {:ok, %RedisCommand.SetNX{key: key, value: value}}

  def parse(["MSETNX" | args]) do
    pairs = parse_pairs(args)
    {:ok, %RedisCommand.MSetNX{pairs: pairs}}
  end

  # Get-and-modify commands
  def parse(["GETSET", key, value]), do: {:ok, %RedisCommand.GetSet{key: key, value: value}}
  def parse(["GETDEL", key]), do: {:ok, %RedisCommand.GetDel{key: key}}

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
    {options, members} = parse_zadd_args(args)
    {:ok, %RedisCommand.ZAdd{key: key, members: members, options: options}}
  end

  def parse(["ZINCRBY", key, increment, member]) do
    {:ok, %RedisCommand.ZIncrBy{key: key, increment: parse_float(increment), member: member}}
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

  def parse(["HMSET", key | args]) do
    fields = parse_pairs(args)
    {:ok, %RedisCommand.HMSet{key: key, fields: fields}}
  end

  def parse(["HSETNX", key, field, value]) do
    {:ok, %RedisCommand.HSetNX{key: key, field: field, value: value}}
  end

  def parse(["HINCRBY", key, field, increment]) do
    {:ok, %RedisCommand.HIncrBy{key: key, field: field, increment: String.to_integer(increment)}}
  end

  def parse(["HINCRBYFLOAT", key, field, increment]) do
    require Logger
    Logger.debug("Parsing HINCRBYFLOAT: key=#{key}, field=#{field}, increment=#{increment}")
    {:ok, %RedisCommand.HIncrByFloat{key: key, field: field, increment: parse_float(increment)}}
  end

  def parse(["HDEL", key | fields]), do: {:ok, %RedisCommand.HDel{key: key, fields: fields}}

  # HGETEX key [EX seconds | PX milliseconds | EXAT unix-time-seconds | PXAT unix-time-milliseconds | PERSIST] FIELDS numfields field [field ...]
  def parse(["HGETEX", key | rest]) do
    {ttl_option, fields} = parse_hgetex_args(rest)
    {:ok, %RedisCommand.HGetEX{key: key, ttl_option: ttl_option, fields: fields}}
  end

  # Hash field expiration commands (Redis 7.4.0+)
  # HEXPIRE key seconds [NX | XX | GT | LT] FIELDS numfields field [field ...]
  def parse(["HEXPIRE", key, seconds | rest]) do
    {condition, fields} = parse_hexpire_args(rest)
    {:ok, %RedisCommand.HExpire{key: key, seconds: String.to_integer(seconds), condition: condition, fields: fields}}
  end

  # HEXPIREAT key unix-time-seconds [NX | XX | GT | LT] FIELDS numfields field [field ...]
  def parse(["HEXPIREAT", key, timestamp | rest]) do
    {condition, fields} = parse_hexpire_args(rest)
    {:ok, %RedisCommand.HExpireAt{key: key, timestamp: String.to_integer(timestamp), condition: condition, fields: fields}}
  end

  # HPEXPIRE key milliseconds [NX | XX | GT | LT] FIELDS numfields field [field ...]
  def parse(["HPEXPIRE", key, milliseconds | rest]) do
    {condition, fields} = parse_hexpire_args(rest)
    {:ok, %RedisCommand.HPExpire{key: key, milliseconds: String.to_integer(milliseconds), condition: condition, fields: fields}}
  end

  # HPEXPIREAT key unix-time-milliseconds [NX | XX | GT | LT] FIELDS numfields field [field ...]
  def parse(["HPEXPIREAT", key, timestamp_ms | rest]) do
    {condition, fields} = parse_hexpire_args(rest)
    {:ok, %RedisCommand.HPExpireAt{key: key, timestamp_ms: String.to_integer(timestamp_ms), condition: condition, fields: fields}}
  end

  # HPERSIST key FIELDS numfields field [field ...]
  def parse(["HPERSIST", key | rest]) do
    {_condition, fields} = parse_hexpire_args(rest)
    {:ok, %RedisCommand.HPersist{key: key, fields: fields}}
  end

  # HSETEX - extended HSET with options (used in replication for HINCRBYFLOAT)
  # Format: HSETEX key [FNX | FXX] [EX seconds | PX milliseconds | EXAT unix-time-seconds | PXAT unix-time-milliseconds | KEEPTTL] FIELDS numfields field value [field value ...]
  # We ignore TTL options and treat FNX/FXX as regular HSET
  def parse(["HSETEX", key | args]) do
    parse_hsetex(key, args)
  end

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
  def parse(args) do
    require Logger
    if is_list(args) and length(args) > 0 do
      cmd = hd(args)
      if is_binary(cmd) and String.upcase(cmd) =~ ~r/HINCR/ do
        Logger.warning("HINCR command fell through to Generic: #{inspect(args)}")
      end
    end
    {:ok, %RedisCommand.Generic{args: args}}
  end

  # Helper functions

  defp parse_pairs([]), do: []
  defp parse_pairs([k, v | rest]), do: [{k, v} | parse_pairs(rest)]

  defp parse_zadd_args(args) do
    {options, rest} = extract_zadd_options(args, [])
    members = parse_score_member_pairs(rest)
    {options, members}
  end

  defp extract_zadd_options([], acc), do: {Enum.reverse(acc), []}

  defp extract_zadd_options([arg | rest] = all_args, acc) do
    case String.upcase(arg) do
      "NX" -> extract_zadd_options(rest, [:nx | acc])
      "XX" -> extract_zadd_options(rest, [:xx | acc])
      "GT" -> extract_zadd_options(rest, [:gt | acc])
      "LT" -> extract_zadd_options(rest, [:lt | acc])
      "CH" -> extract_zadd_options(rest, [:ch | acc])
      "INCR" -> extract_zadd_options(rest, [:incr | acc])
      # Not an option, start of score-member pairs
      _ -> {Enum.reverse(acc), all_args}
    end
  end

  defp parse_score_member_pairs([]), do: []

  defp parse_score_member_pairs([score_str, member | rest]) do
    score = parse_float(score_str)
    [{score, member} | parse_score_member_pairs(rest)]
  end

  defp parse_float("inf"), do: :pos_inf
  defp parse_float("+inf"), do: :pos_inf
  defp parse_float("-inf"), do: :neg_inf
  defp parse_float("nan"), do: :nan

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

  defp parse_hsetex(key, args) do
    # Extract FNX/FXX options and skip TTL options
    {nx_or_xx, rest} = extract_hsetex_options(args)

    # Should now be at ["FIELDS", numfields, field, value, ...]
    case rest do
      ["FIELDS", _numfields | field_value_args] ->
        fields = parse_pairs(field_value_args)
        {:ok, %RedisCommand.HSetEX{key: key, nx_xx_option: nx_or_xx, fields: fields}}

      _ ->
        # Malformed HSETEX, treat as generic
        {:ok, %RedisCommand.Generic{args: ["HSETEX", key | args]}}
    end
  end

  defp extract_hsetex_options(args) do
    extract_hsetex_options(args, nil)
  end

  # Parse HEXPIRE/HEXPIREAT/HPEXPIRE/HPEXPIREAT/HPERSIST args:
  # [NX | XX | GT | LT] FIELDS numfields field [field ...]
  defp parse_hexpire_args(args) do
    {condition, rest} = extract_hexpire_condition(args)
    fields = extract_hexpire_fields(rest)
    {condition, fields}
  end

  defp extract_hexpire_condition([arg | rest]) do
    case String.upcase(arg) do
      "NX" -> {:nx, rest}
      "XX" -> {:xx, rest}
      "GT" -> {:gt, rest}
      "LT" -> {:lt, rest}
      _ -> {nil, [arg | rest]}
    end
  end
  defp extract_hexpire_condition([]), do: {nil, []}

  defp extract_hexpire_fields(["FIELDS", _numfields | fields]), do: fields
  defp extract_hexpire_fields(_), do: []

  # Parse HGETEX args: [EX seconds | PX milliseconds | EXAT unix-time | PXAT unix-time-ms | PERSIST] FIELDS numfields field [field ...]
  defp parse_hgetex_args(args) do
    {ttl_option, rest} = extract_hgetex_ttl_option(args)
    fields = extract_hexpire_fields(rest)
    {ttl_option, fields}
  end

  defp extract_hgetex_ttl_option([arg | rest]) do
    case String.upcase(arg) do
      "EX" -> {{:ex, String.to_integer(hd(rest))}, tl(rest)}
      "PX" -> {{:px, String.to_integer(hd(rest))}, tl(rest)}
      "EXAT" -> {{:exat, String.to_integer(hd(rest))}, tl(rest)}
      "PXAT" -> {{:pxat, String.to_integer(hd(rest))}, tl(rest)}
      "PERSIST" -> {:persist, rest}
      _ -> {nil, [arg | rest]}
    end
  end
  defp extract_hgetex_ttl_option([]), do: {nil, []}

  defp extract_hsetex_options([], nx_or_xx), do: {nx_or_xx, []}

  defp extract_hsetex_options([arg | rest] = all_args, nx_or_xx) do
    case String.upcase(arg) do
      "FNX" -> extract_hsetex_options(rest, :nx)
      "FXX" -> extract_hsetex_options(rest, :xx)
      "KEEPTTL" -> extract_hsetex_options(rest, nx_or_xx)
      # These options have a value after them, skip both
      "EX" -> extract_hsetex_options(Enum.drop(rest, 1), nx_or_xx)
      "PX" -> extract_hsetex_options(Enum.drop(rest, 1), nx_or_xx)
      "EXAT" -> extract_hsetex_options(Enum.drop(rest, 1), nx_or_xx)
      "PXAT" -> extract_hsetex_options(Enum.drop(rest, 1), nx_or_xx)
      # Not an option, return remaining args
      _ -> {nx_or_xx, all_args}
    end
  end
end
