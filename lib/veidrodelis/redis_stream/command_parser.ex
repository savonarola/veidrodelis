defmodule Vdr.RedisStream.CommandParser do
  @moduledoc """
  This is an internal module for parsing Redis commands into command tuples.

  Parses Redis replication stream commands into command tuples.
  """

  @doc """
  Parse a Redis command represented as a list of binary arguments into a command tuple.

  Returns `{:ok, command_tuple, affected_keys}` for all commands. Unknown commands return a generic tuple.

  ## Examples

      iex> parse(["SET", "key", "value"])
      {:ok, {:set, "key", "value"}, ["key"]}

      iex> parse(["SADD", "myset", "m1", "m2"])
      {:ok, {:sadd, "myset", ["m1", "m2"]}, ["myset"]}

      iex> parse(["UNKNOWN", "arg"])
      {:ok, {:generic, ["UNKNOWN", "arg"]}, []}
  """
  @spec parse([binary()]) :: {:ok, tuple(), [binary()]}
  def parse(["SET", key, value | options]) when length(options) > 0 do
    ## We ignore expiration, because we never become a primary node.
    ## All deletion of keys must be issued by the node we are replica of.
    {:ok, {:set, key, value}, [key]}
  end

  def parse(["SET", key, value]), do: {:ok, {:set, key, value}, [key]}

  def parse(["MSET" | args]) do
    pairs = parse_pairs(args)
    keys = Enum.map(pairs, fn {k, _v} -> k end)
    {:ok, {:mset, pairs}, keys}
  end

  def parse(["APPEND", key, value]), do: {:ok, {:append, key, value}, [key]}

  def parse(["SETRANGE", key, offset, value]) do
    {:ok, {:setrange, key, String.to_integer(offset), value}, [key]}
  end

  def parse(["SETBIT", key, offset, value]) do
    bit_value = String.to_integer(value)
    {:ok, {:setbit, key, String.to_integer(offset), bit_value}, [key]}
  end

  def parse(["INCR", key]),
    do: {:ok, {:incr, key}, [key]}

  def parse(["INCRBY", key, increment]),
    do: {:ok, {:incrby, key, String.to_integer(increment)}, [key]}

  def parse(["DECR", key]), do: {:ok, {:decr, key}, [key]}

  def parse(["DECRBY", key, decrement]),
    do: {:ok, {:decrby, key, String.to_integer(decrement)}, [key]}

  def parse(["SETNX", key, value]), do: {:ok, {:setnx, key, value}, [key]}

  def parse(["MSETNX" | args]) do
    pairs = parse_pairs(args)
    keys = Enum.map(pairs, fn {k, _v} -> k end)
    {:ok, {:msetnx, pairs}, keys}
  end

  def parse(["GETSET", key, value]), do: {:ok, {:getset, key, value}, [key]}

  def parse(["GETDEL", key]), do: {:ok, {:getdel, key}, [key]}

  def parse(["LPUSH", key | values]), do: {:ok, {:lpush, key, values}, [key]}

  def parse(["RPUSH", key | values]), do: {:ok, {:rpush, key, values}, [key]}

  def parse(["LPUSHX", key | values]), do: {:ok, {:lpushx, key, values}, [key]}

  def parse(["RPUSHX", key | values]), do: {:ok, {:rpushx, key, values}, [key]}

  def parse(["LPOP", key]), do: {:ok, {:lpop, key}, [key]}

  def parse(["LPOP", key, count]), do: {:ok, {:lpop_count, key, String.to_integer(count)}, [key]}

  def parse(["RPOP", key]), do: {:ok, {:rpop, key}, [key]}

  def parse(["RPOP", key, count]), do: {:ok, {:rpop_count, key, String.to_integer(count)}, [key]}

  def parse(["LREM", key, count, value]) do
    {:ok, {:lrem, key, String.to_integer(count), value}, [key]}
  end

  def parse(["LTRIM", key, start, stop]) do
    {:ok, {:ltrim, key, String.to_integer(start), String.to_integer(stop)}, [key]}
  end

  def parse(["LSET", key, index, value]) do
    {:ok, {:lset, key, String.to_integer(index), value}, [key]}
  end

  def parse(["LINSERT", key, before_after, pivot, element]) do
    ba =
      case String.upcase(before_after) do
        "BEFORE" -> :before
        "AFTER" -> :after
      end

    {:ok, {:linsert, key, ba, pivot, element}, [key]}
  end

  def parse(["RPOPLPUSH", source, destination]) do
    {:ok, {:rpoplpush, source, destination}, [source, destination]}
  end

  def parse(["LMOVE", source_key, dest_key, wherefrom, whereto]) do
    wherefrom =
      case String.upcase(wherefrom) do
        "LEFT" -> :left
        "RIGHT" -> :right
      end

    whereto =
      case String.upcase(whereto) do
        "LEFT" -> :left
        "RIGHT" -> :right
      end

    {:ok, {:lmove, source_key, dest_key, wherefrom, whereto}, [source_key, dest_key]}
  end

  # Set commands
  def parse(["SADD", key | members]), do: {:ok, {:sadd, key, members}, [key]}

  def parse(["SREM", key | members]), do: {:ok, {:srem, key, members}, [key]}

  def parse(["SMOVE", source_key, dest_key, member]) do
    {:ok, {:smove, source_key, dest_key, member}, [source_key, dest_key]}
  end

  def parse(["SINTERSTORE", dest_key | source_keys]) do
    {:ok, {:sinterstore, dest_key, source_keys}, [dest_key | source_keys]}
  end

  def parse(["SUNIONSTORE", dest_key | source_keys]) do
    {:ok, {:sunionstore, dest_key, source_keys}, [dest_key | source_keys]}
  end

  def parse(["SDIFFSTORE", dest_key | source_keys]) do
    {:ok, {:sdiffstore, dest_key, source_keys}, [dest_key | source_keys]}
  end

  # Sorted set commands
  def parse(["ZADD", key | args]) do
    {options, members} = parse_zadd_args(args)
    {:ok, {:zadd, key, members, options}, [key]}
  end

  def parse(["ZINCRBY", key, increment, member]) do
    {:ok, {:zincrby, key, parse_float(increment), member}, [key]}
  end

  def parse(["ZREM", key | members]), do: {:ok, {:zrem, key, members}, [key]}

  def parse(["ZPOPMAX", key]) do
    {:ok, {:zpopmax, key, 1}, [key]}
  end

  def parse(["ZPOPMAX", key, count]) do
    {:ok, {:zpopmax, key, String.to_integer(count)}, [key]}
  end

  def parse(["ZPOPMIN", key]) do
    {:ok, {:zpopmin, key, 1}, [key]}
  end

  def parse(["ZPOPMIN", key, count]) do
    {:ok, {:zpopmin, key, String.to_integer(count)}, [key]}
  end

  def parse(["ZREMRANGEBYRANK", key, start, stop]) do
    {:ok, {:zremrangebyrank, key, String.to_integer(start), String.to_integer(stop)}, [key]}
  end

  def parse(["ZREMRANGEBYSCORE", key, min_str, max_str]) do
    min_bound = parse_score_bound(min_str)
    max_bound = parse_score_bound(max_str)
    {:ok, {:zremrangebyscore, key, min_bound, max_bound}, [key]}
  end

  def parse(["ZREMRANGEBYLEX", key, min_str, max_str]) do
    min_bound = parse_lex_bound(min_str)
    max_bound = parse_lex_bound(max_str)
    {:ok, {:zremrangebylex, key, min_bound, max_bound}, [key]}
  end

  def parse(["ZRANGESTORE", dest_key, source_key, min_str, max_str | options]) do
    opts = (options || []) |> Enum.map(&String.upcase/1)
    {:ok, {:zrangestore, dest_key, source_key, min_str, max_str, opts}, [dest_key, source_key]}
  end

  def parse(["ZUNIONSTORE", destination, _numkeys | rest]) do
    parse_zstore_command(destination, rest, :union)
  end

  def parse(["ZINTERSTORE", destination, _numkeys | rest]) do
    parse_zstore_command(destination, rest, :inter)
  end

  def parse(["ZDIFFSTORE", dest_key, _numkeys | source_keys]) do
    {:ok, {:zdiffstore, dest_key, source_keys}, [dest_key | source_keys]}
  end

  def parse(["HSET", key | args]) do
    fields = parse_pairs(args)
    {:ok, {:hmset, key, fields}, [key]}
  end

  def parse(["HMSET", key | args]) do
    fields = parse_pairs(args)
    {:ok, {:hmset, key, fields}, [key]}
  end

  def parse(["HSETNX", key, field, value]) do
    {:ok, {:hsetnx, key, field, value}, [key]}
  end

  def parse(["HINCRBY", key, field, increment]) do
    {:ok, {:hincrby, key, field, String.to_integer(increment)}, [key]}
  end

  def parse(["HINCRBYFLOAT", key, field, increment]) do
    require Logger
    Logger.debug("Parsing HINCRBYFLOAT: key=#{key}, field=#{field}, increment=#{increment}")
    {:ok, {:hincrbyfloat, key, field, parse_float(increment)}, [key]}
  end

  def parse(["HDEL", key | fields]), do: {:ok, {:hdel, key, fields}, [key]}

  def parse(["HGETEX", key | rest]) do
    {ttl_option, fields} = parse_hgetex_args(rest)
    {:ok, {:hgetex, key, ttl_option, fields}, [key]}
  end

  def parse(["HEXPIRE", key, seconds | rest]) do
    {condition, fields} = parse_hexpire_args(rest)
    {:ok, {:hexpire, key, String.to_integer(seconds), condition, fields}, [key]}
  end

  def parse(["HEXPIREAT", key, timestamp | rest]) do
    {condition, fields} = parse_hexpire_args(rest)
    {:ok, {:hexpireat, key, String.to_integer(timestamp), condition, fields}, [key]}
  end

  def parse(["HPEXPIRE", key, milliseconds | rest]) do
    {condition, fields} = parse_hexpire_args(rest)
    {:ok, {:hpexpire, key, String.to_integer(milliseconds), condition, fields}, [key]}
  end

  def parse(["HPEXPIREAT", key, timestamp_ms | rest]) do
    {condition, fields} = parse_hexpire_args(rest)
    {:ok, {:hpexpireat, key, String.to_integer(timestamp_ms), condition, fields}, [key]}
  end

  def parse(["HPERSIST", key | rest]) do
    {_condition, fields} = parse_hexpire_args(rest)
    {:ok, {:hpersist, key, fields}, [key]}
  end

  def parse(["HSETEX", key | args]) do
    parse_hsetex(key, args)
  end

  def parse(["DEL" | keys]), do: {:ok, {:del, keys}, keys}

  def parse(["UNLINK" | keys]), do: {:ok, {:del, keys}, keys}

  def parse(["COPY", source, destination | options]) do
    replace = "REPLACE" in Enum.map(options, &String.upcase/1)
    {:ok, {:copy, source, destination, replace}, [source, destination]}
  end

  def parse(["RENAME", old_key, new_key]) do
    {:ok, {:rename, old_key, new_key}, [old_key, new_key]}
  end

  def parse(["RENAMENX", old_key, new_key]) do
    {:ok, {:renamenx, old_key, new_key}, [old_key, new_key]}
  end

  def parse(["MOVE", key, target_db]) do
    {:ok, {:move_key, key, String.to_integer(target_db)}, [key]}
  end

  def parse(["PEXPIREAT", key, timestamp_ms]) do
    {:ok, {:pexpireat, key, String.to_integer(timestamp_ms)}, [key]}
  end

  def parse(["EXPIRE", key, seconds | _options]) do
    timestamp_ms = (System.os_time(:second) + String.to_integer(seconds)) * 1000
    {:ok, {:pexpireat, key, timestamp_ms}, [key]}
  end

  def parse(["PEXPIRE", key, milliseconds | _options]) do
    timestamp_ms = System.os_time(:millisecond) + String.to_integer(milliseconds)
    {:ok, {:pexpireat, key, timestamp_ms}, [key]}
  end

  def parse(["EXPIREAT", key, timestamp | _options]) do
    timestamp_ms = String.to_integer(timestamp) * 1000
    {:ok, {:pexpireat, key, timestamp_ms}, [key]}
  end

  def parse(["PERSIST", key]) do
    {:ok, {:persist, key}, [key]}
  end

  def parse(["FLUSHALL" | _options]) do
    {:ok, {:flushall}, []}
  end

  def parse(["FLUSHDB" | _options]) do
    {:ok, {:flushdb}, []}
  end

  def parse(["SWAPDB", db1, db2]) do
    {:ok, {:swapdb, String.to_integer(db1), String.to_integer(db2)}, []}
  end

  def parse(args) do
    {:ok, {:generic, args}, []}
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

  defp parse_zstore_command(dest_key, args, type) do
    {source_keys, rest} = Enum.split_while(args, &(&1 not in ["WEIGHTS", "AGGREGATE"]))

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

    # Default weights to 1.0 for each key if not provided
    weights_list = weights || Enum.map(source_keys, fn _ -> 1.0 end)
    # Default aggregate to :sum if not provided
    aggregate_atom = aggregate || :sum

    command =
      case type do
        :union ->
          {:zunionstore, dest_key, source_keys, weights_list, aggregate_atom}

        :inter ->
          {:zinterstore, dest_key, source_keys, weights_list, aggregate_atom}
      end

    {:ok, command, [dest_key | source_keys]}
  end

  defp parse_hsetex(key, args) do
    # Extract FNX/FXX options and skip TTL options
    {nx_or_xx, rest} = extract_hsetex_options(args)

    # Should now be at ["FIELDS", numfields, field, value, ...]
    case rest do
      ["FIELDS", _numfields | field_value_args] ->
        fields = parse_pairs(field_value_args)
        {:ok, {:hsetex, key, nx_or_xx, fields}, [key]}

      _ ->
        # Malformed HSETEX, treat as generic
        {:ok, {:generic, ["HSETEX", key | args]}, []}
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

  # Helper to parse score strings to floats (handles "-inf", "+inf", etc.)
  defp parse_score_to_float(str) when is_binary(str) do
    case str do
      "-inf" ->
        :neg_infinity

      "+inf" ->
        :infinity

      "inf" ->
        :infinity

      str ->
        case Float.parse(str) do
          {float, _} -> float
          :error -> String.to_integer(str) * 1.0
        end
    end
  end

  # Parse score bound from string to Bound tuple
  # Returns: :unbounded | {:included, score} | {:excluded, score}
  defp parse_score_bound(str) do
    cond do
      # Check for exclusive prefix "("
      String.starts_with?(str, "(") ->
        score_str = String.slice(str, 1..-1//1)
        score = parse_score_to_float(score_str)
        {:excluded, score}

      # Otherwise inclusive
      true ->
        score = parse_score_to_float(str)

        if score == :neg_infinity or score == :infinity do
          :unbounded
        else
          {:included, score}
        end
    end
  end

  # Parse lexicographic bound from string to Bound tuple
  # Returns: :unbounded | {:included, value} | {:excluded, value}
  # Syntax: - (unbounded min), + (unbounded max), [value (inclusive), (value (exclusive)
  defp parse_lex_bound(str) do
    cond do
      str == "-" or str == "+" ->
        :unbounded

      String.starts_with?(str, "[") ->
        value = String.slice(str, 1..-1//1)
        {:included, value}

      String.starts_with?(str, "(") ->
        value = String.slice(str, 1..-1//1)
        {:excluded, value}

      # Default to inclusive if no prefix
      true ->
        {:included, str}
    end
  end
end
