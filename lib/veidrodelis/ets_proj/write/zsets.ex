defmodule Vdr.ETSProj.Write.ZSets do
  @moduledoc """
  Write operations for Redis sorted set (zset) store.

  Uses a shared ETS table with a dual-entry layout for each member:
  - `{{db, key, :zset, decoded_set_entry}, weight}` - for member lookups and deletions
  - `{{db, key, :zset_index, {weight, decoded_set_entry}}, nil}` - for score-range operations
  """

  defstruct [:tid, :decode_fun]

  @type t :: %__MODULE__{
          tid: :ets.tid(),
          decode_fun: decode_fun()
        }

  @type db :: non_neg_integer()
  @type key :: any()
  @type member :: binary()
  @type score :: float()
  @type decode_fun :: (key(), member() -> any())
  @type aggregate :: :sum | :min | :max

  @doc """
  Creates a new zset store with the given ETS table and decode function.
  """
  @spec new(:ets.tid(), decode_fun()) :: t()
  def new(tid, decode_fun) when is_function(decode_fun, 2) do
    %__MODULE__{tid: tid, decode_fun: decode_fun}
  end

  @doc """
  Adds one or more members with scores to a sorted set.
  """
  @spec zadd(t(), db(), key(), [{score(), member()}]) :: :ok
  def zadd(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, score_members)
      when is_list(score_members) do
    Enum.each(score_members, fn {score, member} ->
      decoded_value = decode_fun.(key, member)

      case :ets.lookup(tid, {db, key, :zset, decoded_value}) do
        [{_, old_score}] ->
          :ets.delete(tid, {db, key, :zset_index, {old_score, decoded_value}})

        [] ->
          :ok
      end

      :ets.insert(tid, {{db, key, :zset, decoded_value}, score})
      :ets.insert(tid, {{db, key, :zset_index, {score, decoded_value}}, nil})
    end)

    :ok
  end

  @doc """
  Adds a member with its final score to a sorted set.
  """
  @spec zadd_final(t(), db(), key(), score(), member()) :: :ok
  def zadd_final(store, db, key, final_score, member) do
    zadd(store, db, key, [{final_score, member}])
  end

  @doc """
  Removes one or more members from a sorted set.
  """
  @spec zrem(t(), db(), key(), [member()]) :: :ok
  def zrem(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, members)
      when is_list(members) do
    Enum.each(members, fn member ->
      decoded_value = decode_fun.(key, member)

      case :ets.lookup(tid, {db, key, :zset, decoded_value}) do
        [{_, score}] ->
          :ets.delete(tid, {db, key, :zset, decoded_value})
          :ets.delete(tid, {db, key, :zset_index, {score, decoded_value}})

        [] ->
          :ok
      end
    end)

    :ok
  end

  @doc """
  Removes all members in the given rank range.
  """
  @spec zremrangebyrank(t(), db(), key(), integer(), integer()) :: :ok
  def zremrangebyrank(%__MODULE__{tid: tid}, db, key, start, stop) do
    members = zrange_with_scores(tid, db, key, 0, -1)

    count = length(members)
    start_idx = if start < 0, do: max(0, count + start), else: start
    stop_idx = if stop < 0, do: max(-1, count + stop), else: stop

    members_to_remove =
      members
      |> Enum.slice(start_idx..stop_idx)

    Enum.each(members_to_remove, fn {decoded_value, score} ->
      :ets.delete(tid, {db, key, :zset, decoded_value})
      :ets.delete(tid, {db, key, :zset_index, {score, decoded_value}})
    end)

    :ok
  end

  @doc """
  Removes all members with scores in the given range.
  """
  @spec zremrangebyscore(
          t(),
          db(),
          key(),
          score() | :neg_inf | :pos_inf,
          score() | :neg_inf | :pos_inf
        ) :: :ok
  def zremrangebyscore(%__MODULE__{tid: tid}, db, key, min, max) do
    match_head = {{db, key, :zset_index, {:"$1", :"$2"}}, :_}
    match_spec = [{match_head, [], [{{:"$1", :"$2"}}]}]

    all_members = :ets.select(tid, match_spec)

    members_to_remove =
      all_members
      |> Enum.filter(fn {score, _decoded_value} ->
        score_in_range?(score, min, max)
      end)

    Enum.each(members_to_remove, fn {score, decoded_value} ->
      :ets.delete(tid, {db, key, :zset_index, {score, decoded_value}})
      :ets.delete(tid, {db, key, :zset, decoded_value})
    end)

    :ok
  end

  @doc """
  Removes all members in the given lexicographical range.
  """
  @spec zremrangebylex(t(), db(), key(), any(), any()) :: :ok
  def zremrangebylex(%__MODULE__{tid: tid}, db, key, min, max) do
    match_head = {{db, key, :zset, :"$1"}, :_}
    match_spec = [{match_head, [], [:"$1"]}]

    all_decoded_values = :ets.select(tid, match_spec)

    decoded_values_to_remove =
      all_decoded_values
      |> Enum.filter(fn decoded_value ->
        lex_in_range?(decoded_value, min, max)
      end)

    Enum.each(decoded_values_to_remove, fn decoded_value ->
      case :ets.lookup(tid, {db, key, :zset, decoded_value}) do
        [{_, score}] ->
          :ets.delete(tid, {db, key, :zset, decoded_value})
          :ets.delete(tid, {db, key, :zset_index, {score, decoded_value}})

        [] ->
          :ok
      end
    end)

    :ok
  end

  @doc """
  Removes and returns up to count members with the lowest scores.
  """
  @spec zpopmin(t(), db(), key(), pos_integer()) :: [{any(), score()}]
  def zpopmin(%__MODULE__{tid: tid}, db, key, count \\ 1) do
    match_head = {{db, key, :zset_index, {:"$1", :"$2"}}, :_}
    match_spec = [{match_head, [], [{{:"$2", :"$1"}}]}]

    members_to_pop =
      :ets.select(tid, match_spec)
      |> Enum.take(count)

    Enum.each(members_to_pop, fn {decoded_value, score} ->
      :ets.delete(tid, {db, key, :zset_index, {score, decoded_value}})
      :ets.delete(tid, {db, key, :zset, decoded_value})
    end)

    members_to_pop
  end

  @doc """
  Removes and returns up to count members with the highest scores.
  """
  @spec zpopmax(t(), db(), key(), pos_integer()) :: [{any(), score()}]
  def zpopmax(%__MODULE__{tid: tid}, db, key, count \\ 1) do
    match_head = {{db, key, :zset_index, {:"$1", :"$2"}}, :_}
    match_spec = [{match_head, [], [{{:"$2", :"$1"}}]}]

    all_members = :ets.select(tid, match_spec)

    members_to_pop =
      all_members
      |> Enum.take(-count)
      |> Enum.reverse()

    Enum.each(members_to_pop, fn {decoded_value, score} ->
      :ets.delete(tid, {db, key, :zset_index, {score, decoded_value}})
      :ets.delete(tid, {db, key, :zset, decoded_value})
    end)

    members_to_pop
  end

  @doc """
  Computes the union of multiple sorted sets and stores the result.
  """
  @spec zunionstore(t(), db(), key(), [key()], [float()], aggregate()) :: :ok
  def zunionstore(
        %__MODULE__{tid: tid},
        db,
        destination,
        keys,
        weights \\ [],
        aggregate \\ :sum
      ) do
    weights = normalize_weights(keys, weights)

    member_scores =
      keys
      |> Enum.zip(weights)
      |> Enum.flat_map(fn {source_key, weight} ->
        match_head = {{db, source_key, :zset, :"$1"}, :"$2"}
        match_spec = [{match_head, [], [{{:"$1", :"$2"}}]}]

        :ets.select(tid, match_spec)
        |> Enum.map(fn {decoded_value, score} -> {decoded_value, score * weight} end)
      end)

    aggregated =
      member_scores
      |> Enum.group_by(fn {decoded_value, _score} -> decoded_value end, fn {_, score} -> score end)
      |> Enum.map(fn {decoded_value, scores} ->
        final_score = aggregate_scores(scores, aggregate)
        {final_score, decoded_value}
      end)

    Vdr.ETSProj.Write.Common.del(tid, db, destination)

    Enum.each(aggregated, fn {score, decoded_value} ->
      :ets.insert(tid, {{db, destination, :zset, decoded_value}, score})
      :ets.insert(tid, {{db, destination, :zset_index, {score, decoded_value}}, nil})
    end)

    :ok
  end

  @doc """
  Computes the intersection of multiple sorted sets and stores the result.
  """
  @spec zinterstore(t(), db(), key(), [key()], [float()], aggregate()) :: :ok
  def zinterstore(
        %__MODULE__{tid: tid},
        db,
        destination,
        keys,
        weights \\ [],
        aggregate \\ :sum
      ) do
    weights = normalize_weights(keys, weights)

    key_members =
      keys
      |> Enum.zip(weights)
      |> Enum.map(fn {source_key, weight} ->
        match_head = {{db, source_key, :zset, :"$1"}, :"$2"}
        match_spec = [{match_head, [], [{{:"$1", :"$2"}}]}]

        :ets.select(tid, match_spec)
        |> Enum.map(fn {decoded_value, score} -> {decoded_value, score * weight} end)
        |> Map.new()
      end)

    Vdr.ETSProj.Write.Common.del(tid, db, destination)

    if key_members == [] do
      :ok
    else
      [first_map | rest_maps] = key_members

      common_members =
        first_map
        |> Enum.filter(fn {decoded_value, _score} ->
          Enum.all?(rest_maps, fn map -> Map.has_key?(map, decoded_value) end)
        end)
        |> Enum.map(fn {decoded_value, _score} ->
          scores = Enum.map(key_members, fn map -> Map.fetch!(map, decoded_value) end)
          final_score = aggregate_scores(scores, aggregate)
          {final_score, decoded_value}
        end)

      Enum.each(common_members, fn {score, decoded_value} ->
        :ets.insert(tid, {{db, destination, :zset, decoded_value}, score})
        :ets.insert(tid, {{db, destination, :zset_index, {score, decoded_value}}, nil})
      end)

      :ok
    end
  end

  # Private helpers

  @spec zrange_with_scores(:ets.tid(), db(), key(), integer(), integer()) :: [{any(), score()}]
  defp zrange_with_scores(tid, db, key, start, stop) do
    match_head = {{db, key, :zset_index, {:"$1", :"$2"}}, :_}
    match_spec = [{match_head, [], [{{:"$2", :"$1"}}]}]

    all_members = :ets.select(tid, match_spec)

    count = length(all_members)
    start_idx = if start < 0, do: max(0, count + start), else: start
    stop_idx = if stop < 0, do: max(-1, count + stop), else: stop

    if stop_idx < start_idx or start_idx >= count do
      []
    else
      Enum.slice(all_members, start_idx..stop_idx)
    end
  end

  defp score_in_range?(score, min, max) do
    min_ok =
      case min do
        :neg_inf -> true
        min_score -> score >= min_score
      end

    max_ok =
      case max do
        :pos_inf -> true
        max_score -> score <= max_score
      end

    min_ok and max_ok
  end

  defp lex_in_range?(value, min, max) do
    min_ok =
      case min do
        :neg_inf -> true
        :- -> true
        min_val -> value >= min_val
      end

    max_ok =
      case max do
        :pos_inf -> true
        :+ -> true
        max_val -> value <= max_val
      end

    min_ok and max_ok
  end

  defp normalize_weights(keys, []) do
    List.duplicate(1.0, length(keys))
  end

  defp normalize_weights(keys, weights) do
    weights ++ List.duplicate(1.0, length(keys) - length(weights))
  end

  defp aggregate_scores(scores, :sum), do: Enum.sum(scores)
  defp aggregate_scores(scores, :min), do: Enum.min(scores)
  defp aggregate_scores(scores, :max), do: Enum.max(scores)
end
