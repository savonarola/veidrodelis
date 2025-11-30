defmodule Veidrodelis.ZsetStore do
  @moduledoc """
  An ETS-backed store for Redis sorted set (zset) operations.

  Uses a protected ETS ordered_set table with a dual-entry layout for each member:
  - `{{db, key, score, decoded_value}, nil}` - for score-range operations
  - `{{db, key, decoded_value}, score}` - for member lookups and deletions

  The decode function is called for each member to compute a decoded representation
  that is stored in the ETS keys.
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
  @type entry :: any()
  @type decode_fun :: (key(), member() -> entry())
  @type aggregate :: :sum | :min | :max

  @doc """
  Creates a new zset store with the given decode function.

  The decode function receives `(key, member)` and returns a decoded entry
  that will be used in the ETS keys for efficient matching and ordering.

  Returns a ZsetStore struct containing the table id and decode function.
  """
  @spec new(decode_fun()) :: t()
  def new(decode_fun) when is_function(decode_fun, 2) do
    tid = :ets.new(__MODULE__, [:ordered_set, :protected])
    %__MODULE__{tid: tid, decode_fun: decode_fun}
  end

  @doc """
  Adds one or more members with scores to a sorted set.

  ZADD key score member [score member ...]

  This is the standard form. Each member is added with its score.
  If a member already exists, its score is updated and both ETS entries are synchronized.
  """
  @spec zadd(t(), db(), key(), [{score(), member()}]) :: :ok
  def zadd(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, score_members)
      when is_list(score_members) do
    Enum.each(score_members, fn {score, member} ->
      decoded_value = decode_fun.(key, member)

      # Remove old entries if they exist
      case :ets.lookup(tid, {db, key, decoded_value}) do
        [{_, old_score}] ->
          :ets.delete(tid, {db, key, old_score, decoded_value})

        [] ->
          :ok
      end

      # Insert both entries
      :ets.insert(tid, {{db, key, score, decoded_value}, nil})
      :ets.insert(tid, {{db, key, decoded_value}, score})
    end)

    :ok
  end

  @doc """
  Adds a member with its final score to a sorted set.

  ZADD key <final_score> member

  This is the replicated form for ZINCRBY and conditional ZADD operations.
  The final_score is the absolute score value (not an increment).
  """
  @spec zadd_final(t(), db(), key(), score(), member()) :: :ok
  def zadd_final(store, db, key, final_score, member) do
    zadd(store, db, key, [{final_score, member}])
  end

  @doc """
  Removes one or more members from a sorted set.

  ZREM key member [member ...]
  """
  @spec zrem(t(), db(), key(), [member()]) :: :ok
  def zrem(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, members)
      when is_list(members) do
    Enum.each(members, fn member ->
      decoded_value = decode_fun.(key, member)

      # Lookup the score from the member-lookup entry
      case :ets.lookup(tid, {db, key, decoded_value}) do
        [{_, score}] ->
          # Delete both entries
          :ets.delete(tid, {db, key, decoded_value})
          :ets.delete(tid, {db, key, score, decoded_value})

        [] ->
          :ok
      end
    end)

    :ok
  end

  @doc """
  Removes all members in the given rank range.

  ZREMRANGEBYRANK key start stop

  Ranks are 0-based. Negative ranks count from the end (-1 is the last element).
  Both start and stop are inclusive.
  """
  @spec zremrangebyrank(t(), db(), key(), integer(), integer()) :: :ok
  def zremrangebyrank(%__MODULE__{tid: tid}, db, key, start, stop) do
    # Get all members sorted by score
    members = zrange_with_scores(tid, db, key, 0, -1)

    # Normalize negative indices
    count = length(members)
    start_idx = if start < 0, do: max(0, count + start), else: start
    stop_idx = if stop < 0, do: max(-1, count + stop), else: stop

    # Get members in the range to remove
    members_to_remove =
      members
      |> Enum.slice(start_idx..stop_idx)

    # Remove each member
    Enum.each(members_to_remove, fn {decoded_value, score} ->
      :ets.delete(tid, {db, key, decoded_value})
      :ets.delete(tid, {db, key, score, decoded_value})
    end)

    :ok
  end

  @doc """
  Removes all members with scores in the given range.

  ZREMRANGEBYSCORE key min max

  Min and max are inclusive by default. Use "-inf" and "+inf" for unbounded ranges.
  """
  @spec zremrangebyscore(
          t(),
          db(),
          key(),
          score() | :neg_inf | :pos_inf,
          score() | :neg_inf | :pos_inf
        ) :: :ok
  def zremrangebyscore(%__MODULE__{tid: tid}, db, key, min, max) do
    # Get all members and filter by score
    match_head = {{db, key, :"$1", :"$2"}, :_}
    match_spec = [{match_head, [], [{{:"$1", :"$2"}}]}]

    all_members = :ets.select(tid, match_spec)

    members_to_remove =
      all_members
      |> Enum.filter(fn {score, _decoded_value} ->
        score_in_range?(score, min, max)
      end)

    # Remove both entries for each member
    Enum.each(members_to_remove, fn {score, decoded_value} ->
      :ets.delete(tid, {db, key, score, decoded_value})
      :ets.delete(tid, {db, key, decoded_value})
    end)

    :ok
  end

  @doc """
  Removes all members in the given lexicographical range.

  ZREMRANGEBYLEX key min max

  This only makes sense when all members have the same score.
  Min and max use Redis lex range notation: "[" for inclusive, "(" for exclusive.
  Use "-" for negative infinity and "+" for positive infinity.
  """
  @spec zremrangebylex(t(), db(), key(), any(), any()) :: :ok
  def zremrangebylex(%__MODULE__{tid: tid}, db, key, min, max) do
    # Get all members and filter by lex order
    match_head = {{db, key, :"$1"}, :_}
    match_spec = [{match_head, [], [:"$1"]}]

    all_decoded_values = :ets.select(tid, match_spec)

    decoded_values_to_remove =
      all_decoded_values
      |> Enum.filter(fn decoded_value ->
        lex_in_range?(decoded_value, min, max)
      end)

    # For each decoded value, get its score and delete both entries
    Enum.each(decoded_values_to_remove, fn decoded_value ->
      case :ets.lookup(tid, {db, key, decoded_value}) do
        [{_, score}] ->
          :ets.delete(tid, {db, key, decoded_value})
          :ets.delete(tid, {db, key, score, decoded_value})

        [] ->
          :ok
      end
    end)

    :ok
  end

  @doc """
  Removes and returns up to count members with the lowest scores.

  ZPOPMIN key [count]

  Returns a list of {decoded_value, score} tuples.
  """
  @spec zpopmin(t(), db(), key(), pos_integer()) :: [{entry(), score()}]
  def zpopmin(%__MODULE__{tid: tid}, db, key, count \\ 1) do
    # Use select to get the first count members by score
    match_head = {{db, key, :"$1", :"$2"}, :_}
    match_spec = [{match_head, [], [{{:"$2", :"$1"}}]}]

    all_members = :ets.select(tid, match_spec)
    members_to_pop = Enum.take(all_members, count)

    # Remove both entries for each member
    Enum.each(members_to_pop, fn {decoded_value, score} ->
      :ets.delete(tid, {db, key, score, decoded_value})
      :ets.delete(tid, {db, key, decoded_value})
    end)

    members_to_pop
  end

  @doc """
  Removes and returns up to count members with the highest scores.

  ZPOPMAX key [count]

  Returns a list of {decoded_value, score} tuples.
  """
  @spec zpopmax(t(), db(), key(), pos_integer()) :: [{entry(), score()}]
  def zpopmax(%__MODULE__{tid: tid}, db, key, count \\ 1) do
    # Get all members and take the last count
    match_head = {{db, key, :"$1", :"$2"}, :_}
    match_spec = [{match_head, [], [{{:"$2", :"$1"}}]}]

    all_members = :ets.select(tid, match_spec)

    members_to_pop =
      all_members
      |> Enum.reverse()
      |> Enum.take(count)

    # Remove both entries for each member
    Enum.each(members_to_pop, fn {decoded_value, score} ->
      :ets.delete(tid, {db, key, score, decoded_value})
      :ets.delete(tid, {db, key, decoded_value})
    end)

    members_to_pop
  end

  @doc """
  Computes the union of multiple sorted sets and stores the result.

  ZUNIONSTORE destination numkeys key [key ...] [WEIGHTS weight [weight ...]] [AGGREGATE <SUM | MIN | MAX>]

  The aggregate function determines how scores are combined (default: :sum).
  Weights are multiplied with scores before aggregation (default: 1.0 for all).
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
    # Normalize weights (default to 1.0)
    weights = normalize_weights(keys, weights)

    # Collect all members with their scores from all source keys
    member_scores =
      keys
      |> Enum.zip(weights)
      |> Enum.flat_map(fn {source_key, weight} ->
        match_head = {{db, source_key, :"$1"}, :"$2"}
        match_spec = [{match_head, [], [{{:"$1", :"$2"}}]}]

        :ets.select(tid, match_spec)
        |> Enum.map(fn {decoded_value, score} -> {decoded_value, score * weight} end)
      end)

    # Group by decoded_value and aggregate scores
    aggregated =
      member_scores
      |> Enum.group_by(fn {decoded_value, _score} -> decoded_value end, fn {_, score} -> score end)
      |> Enum.map(fn {decoded_value, scores} ->
        final_score = aggregate_scores(scores, aggregate)
        {final_score, decoded_value}
      end)

    # Clear destination and insert aggregated results
    clear_zset(tid, db, destination)

    Enum.each(aggregated, fn {score, decoded_value} ->
      :ets.insert(tid, {{db, destination, score, decoded_value}, nil})
      :ets.insert(tid, {{db, destination, decoded_value}, score})
    end)

    :ok
  end

  @doc """
  Computes the intersection of multiple sorted sets and stores the result.

  ZINTERSTORE destination numkeys key [key ...] [WEIGHTS weight [weight ...]] [AGGREGATE <SUM | MIN | MAX>]

  Only members present in all source keys are included.
  The aggregate function determines how scores are combined (default: :sum).
  Weights are multiplied with scores before aggregation (default: 1.0 for all).
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
    # Normalize weights
    weights = normalize_weights(keys, weights)

    # Collect members with scores from each key
    key_members =
      keys
      |> Enum.zip(weights)
      |> Enum.map(fn {source_key, weight} ->
        match_head = {{db, source_key, :"$1"}, :"$2"}
        match_spec = [{match_head, [], [{{:"$1", :"$2"}}]}]

        :ets.select(tid, match_spec)
        |> Enum.map(fn {decoded_value, score} -> {decoded_value, score * weight} end)
        |> Map.new()
      end)

    # Find members present in all keys
    if key_members == [] do
      clear_zset(tid, db, destination)
      :ok
    else
      [first_map | rest_maps] = key_members

      common_members =
        first_map
        |> Enum.filter(fn {decoded_value, _score} ->
          Enum.all?(rest_maps, fn map -> Map.has_key?(map, decoded_value) end)
        end)
        |> Enum.map(fn {decoded_value, _score} ->
          # Collect scores from all keys
          scores = Enum.map(key_members, fn map -> Map.fetch!(map, decoded_value) end)
          final_score = aggregate_scores(scores, aggregate)
          {final_score, decoded_value}
        end)

      # Clear destination and insert intersection results
      clear_zset(tid, db, destination)

      Enum.each(common_members, fn {score, decoded_value} ->
        :ets.insert(tid, {{db, destination, score, decoded_value}, nil})
        :ets.insert(tid, {{db, destination, decoded_value}, score})
      end)

      :ok
    end
  end

  @doc """
  Gets the score of a member in a sorted set.

  ZSCORE key member

  Returns the score if the member exists, or nil if it doesn't.
  """
  @spec zscore(t(), db(), key(), member()) :: score() | nil
  def zscore(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, member) do
    decoded_value = decode_fun.(key, member)

    case :ets.lookup(tid, {db, key, decoded_value}) do
      [] -> nil
      [{_, score}] -> score
    end
  end

  @doc """
  Returns the number of members in a sorted set.

  ZCARD key
  """
  @spec zcard(t(), db(), key()) :: non_neg_integer()
  def zcard(%__MODULE__{tid: tid}, db, key) do
    # Count member-lookup entries
    match_spec = [
      {{{db, key, :_}, :_}, [], [true]}
    ]

    :ets.select_count(tid, match_spec)
  end

  @doc """
  Returns members in a sorted set by score order.

  ZRANGE key start stop [WITHSCORES]

  Returns a list of {decoded_value, score} tuples.
  Ranks are 0-based. Negative ranks count from the end.
  """
  @spec zrange(t(), db(), key(), integer(), integer()) :: [{entry(), score()}]
  def zrange(%__MODULE__{tid: tid}, db, key, start, stop) do
    members = zrange_with_scores(tid, db, key, start, stop)
    members
  end

  @doc """
  Returns members in a sorted set by score range.

  ZRANGEBYSCORE key min max

  Returns a list of {decoded_value, score} tuples.
  """
  @spec zrangebyscore(
          t(),
          db(),
          key(),
          score() | :neg_inf | :pos_inf,
          score() | :neg_inf | :pos_inf
        ) :: [{entry(), score()}]
  def zrangebyscore(%__MODULE__{tid: tid}, db, key, min, max) do
    match_head = {{db, key, :"$1", :"$2"}, :_}
    match_spec = [{match_head, [], [{{:"$2", :"$1"}}]}]

    :ets.select(tid, match_spec)
    |> Enum.filter(fn {_decoded_value, score} ->
      score_in_range?(score, min, max)
    end)
  end

  @doc """
  Deletes an entire sorted set.

  DEL key
  """
  @spec del(t(), db(), key()) :: :ok
  def del(%__MODULE__{tid: tid}, db, key) do
    clear_zset(tid, db, key)
    :ok
  end

  @doc """
  Destroys the ETS table and releases resources.
  """
  @spec destroy(t()) :: :ok
  def destroy(%__MODULE__{tid: tid}) do
    :ets.delete(tid)
    :ok
  end

  # Private helpers

  # Clears all entries from a sorted set (both types of entries)
  @spec clear_zset(:ets.tid(), db(), key()) :: :ok
  defp clear_zset(tid, db, key) do
    # Delete score-indexed entries
    score_match_spec = [
      {{{db, key, :_, :_}, :_}, [], [true]}
    ]

    :ets.select_delete(tid, score_match_spec)

    # Delete member-lookup entries
    member_match_spec = [
      {{{db, key, :_}, :_}, [], [true]}
    ]

    :ets.select_delete(tid, member_match_spec)

    :ok
  end

  # Gets members with scores in rank range
  @spec zrange_with_scores(:ets.tid(), db(), key(), integer(), integer()) :: [{entry(), score()}]
  defp zrange_with_scores(tid, db, key, start, stop) do
    # Get all members sorted by score using score-indexed entries
    match_head = {{db, key, :"$1", :"$2"}, :_}
    match_spec = [{match_head, [], [{{:"$2", :"$1"}}]}]

    all_members = :ets.select(tid, match_spec)

    # Normalize negative indices
    count = length(all_members)
    start_idx = if start < 0, do: max(0, count + start), else: start
    stop_idx = if stop < 0, do: max(-1, count + stop), else: stop

    # Return slice
    if stop_idx < start_idx or start_idx >= count do
      []
    else
      Enum.slice(all_members, start_idx..stop_idx)
    end
  end

  # Checks if a score is within the given range
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

  # Checks if a value is within the given lexicographical range
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

  # Normalizes weights list to match number of keys
  defp normalize_weights(keys, []) do
    List.duplicate(1.0, length(keys))
  end

  defp normalize_weights(keys, weights) do
    weights ++ List.duplicate(1.0, length(keys) - length(weights))
  end

  # Aggregates scores according to the specified function
  defp aggregate_scores(scores, :sum), do: Enum.sum(scores)
  defp aggregate_scores(scores, :min), do: Enum.min(scores)
  defp aggregate_scores(scores, :max), do: Enum.max(scores)
end
