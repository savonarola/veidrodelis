defmodule Vdr.MapProj.ZSets do
  @moduledoc """
  Sorted set (zset) operations for MapProj.

  Stores sorted set values using a dual structure:
  - `entries`: gb_tree mapping decoded_member => score for member lookups
  - `index`: gb_set of {score, decoded_member} for score-range queries

  The dual structure allows efficient operations both by member and by score.
  """

  defmodule ZSet do
    @moduledoc false
    defstruct [:entries, :index]

    @type t :: %__MODULE__{
            entries: :gb_trees.tree(),
            index: :gb_sets.set()
          }
  end

  defstruct [:decode_fun]

  @type t :: %__MODULE__{
          decode_fun: decode_fun()
        }

  @type db :: non_neg_integer()
  @type key :: any()
  @type member :: binary()
  @type score :: float()
  @type decode_fun :: (key(), member() -> any())
  @type store :: %{db() => %{key() => ZSet.t()}}
  @type aggregate :: :sum | :min | :max

  @doc """
  Creates a new sorted set store configuration with the given decode function.
  """
  @spec new(decode_fun()) :: t()
  def new(decode_fun) when is_function(decode_fun, 2) do
    %__MODULE__{decode_fun: decode_fun}
  end

  @doc """
  Adds one or more members with scores to a sorted set.
  Returns the updated store.
  """
  @spec zadd(store(), t(), db(), key(), [{score(), member()}]) :: store()
  def zadd(store, %__MODULE__{decode_fun: decode_fun}, db, key, score_members)
      when is_list(score_members) do
    db_map = Map.get(store, db, %{})

    {entries, index} =
      case Map.get(db_map, key) do
        nil -> {:gb_trees.empty(), :gb_sets.new()}
        %ZSet{entries: e, index: i} -> {e, i}
      end

    {new_entries, new_index} =
      Enum.reduce(score_members, {entries, index}, fn {score, member}, {acc_entries, acc_index} ->
        decoded_member = decode_fun.(key, member)

        # Check if member already exists and remove old score from index
        {acc_entries, acc_index} =
          case :gb_trees.lookup(decoded_member, acc_entries) do
            :none ->
              {acc_entries, acc_index}

            {:value, old_score} ->
              # Remove old index entry
              new_index = :gb_sets.del_element({old_score, decoded_member}, acc_index)
              # Remove old entry from tree (will be re-inserted with new score)
              new_entries = :gb_trees.delete(decoded_member, acc_entries)
              {new_entries, new_index}
          end

        # Add new entries
        new_entries = :gb_trees.insert(decoded_member, score, acc_entries)
        new_index = :gb_sets.add_element({score, decoded_member}, acc_index)
        {new_entries, new_index}
      end)

    zset_entry = %ZSet{entries: new_entries, index: new_index}
    new_db_map = Map.put(db_map, key, zset_entry)
    Map.put(store, db, new_db_map)
  end

  @doc """
  Adds a member with its final score to a sorted set.
  Returns the updated store.
  """
  @spec zadd_final(store(), t(), db(), key(), score(), member()) :: store()
  def zadd_final(store, config, db, key, final_score, member) do
    zadd(store, config, db, key, [{final_score, member}])
  end

  @doc """
  Removes one or more members from a sorted set.
  Returns the updated store.
  """
  @spec zrem(store(), t(), db(), key(), [member()]) :: store()
  def zrem(store, %__MODULE__{decode_fun: decode_fun}, db, key, members)
      when is_list(members) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        store

      %ZSet{entries: entries, index: index} ->
        {new_entries, new_index} =
          Enum.reduce(members, {entries, index}, fn member, {acc_entries, acc_index} ->
            decoded_member = decode_fun.(key, member)

            case :gb_trees.lookup(decoded_member, acc_entries) do
              :none ->
                {acc_entries, acc_index}

              {:value, score} ->
                new_entries = :gb_trees.delete(decoded_member, acc_entries)
                new_index = :gb_sets.del_element({score, decoded_member}, acc_index)
                {new_entries, new_index}
            end
          end)

        store_entries(store, db, key, new_entries, new_index)
    end
  end

  @doc """
  Removes all members in the given rank range.
  Returns the updated store.
  """
  @spec zremrangebyrank(store(), db(), key(), integer(), integer()) :: store()
  def zremrangebyrank(store, db, key, start, stop) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        store

      %ZSet{entries: entries, index: index} ->
        # Use iterator to get only the required range
        count = :gb_sets.size(index)
        start_idx = if start < 0, do: max(0, count + start), else: start
        stop_idx = if stop < 0, do: max(-1, count + stop), else: stop

        members_to_remove =
          if stop_idx < start_idx or start_idx >= count do
            []
          else
            take_range_from_iterator(:gb_sets.iterator(index), start_idx, stop_idx)
          end

        {new_entries, new_index} =
          Enum.reduce(members_to_remove, {entries, index}, fn {decoded_member, score},
                                                               {acc_entries, acc_index} ->
            new_entries = :gb_trees.delete(decoded_member, acc_entries)
            new_index = :gb_sets.del_element({score, decoded_member}, acc_index)
            {new_entries, new_index}
          end)

        store_entries(store, db, key, new_entries, new_index)
    end
  end

  @doc """
  Removes all members with scores in the given range.
  Returns the updated store.
  """
  @spec zremrangebyscore(
          store(),
          db(),
          key(),
          score() | :neg_inf | :pos_inf,
          score() | :neg_inf | :pos_inf
        ) :: store()
  def zremrangebyscore(store, db, key, min, max) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        store

      %ZSet{entries: entries, index: index} ->
        # Use iterator and filter by score range
        members_to_remove = filter_by_score_iterator(:gb_sets.iterator(index), min, max, [])

        {new_entries, new_index} =
          Enum.reduce(members_to_remove, {entries, index}, fn {decoded_member, score},
                                                               {acc_entries, acc_index} ->
            new_entries = :gb_trees.delete(decoded_member, acc_entries)
            new_index = :gb_sets.del_element({score, decoded_member}, acc_index)
            {new_entries, new_index}
          end)

        store_entries(store, db, key, new_entries, new_index)
    end
  end

  @doc """
  Removes all members in the given lexicographical range.
  Returns the updated store.
  """
  @spec zremrangebylex(store(), db(), key(), any(), any()) :: store()
  def zremrangebylex(store, db, key, min, max) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        store

      %ZSet{entries: entries, index: index} ->
        # Use iterator and filter by lex range
        members_to_remove = filter_by_lex_iterator(:gb_sets.iterator(index), min, max, [])

        {new_entries, new_index} =
          Enum.reduce(members_to_remove, {entries, index}, fn {decoded_member, score},
                                                               {acc_entries, acc_index} ->
            new_entries = :gb_trees.delete(decoded_member, acc_entries)
            new_index = :gb_sets.del_element({score, decoded_member}, acc_index)
            {new_entries, new_index}
          end)

        store_entries(store, db, key, new_entries, new_index)
    end
  end

  @doc """
  Removes and returns up to count members with the lowest scores.
  Returns {updated_store, popped_members}.
  """
  @spec zpopmin(store(), db(), key(), pos_integer()) :: {store(), [{any(), score()}]}
  def zpopmin(store, db, key, count \\ 1) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        {store, []}

      %ZSet{entries: entries, index: index} ->
        # Use iterator to get first count members efficiently
        members_to_pop = take_from_iterator(:gb_sets.iterator(index), count, [])

        {new_entries, new_index} =
          Enum.reduce(members_to_pop, {entries, index}, fn {decoded_member, score},
                                                            {acc_entries, acc_index} ->
            new_entries = :gb_trees.delete(decoded_member, acc_entries)
            new_index = :gb_sets.del_element({score, decoded_member}, acc_index)
            {new_entries, new_index}
          end)

        new_store = store_entries(store, db, key, new_entries, new_index)
        {new_store, members_to_pop}
    end
  end

  @doc """
  Removes and returns up to count members with the highest scores.
  Returns {updated_store, popped_members}.
  """
  @spec zpopmax(store(), db(), key(), pos_integer()) :: {store(), [{any(), score()}]}
  def zpopmax(store, db, key, count \\ 1) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        {store, []}

      %ZSet{entries: entries, index: index} ->
        # Use reverse iterator to get highest scoring members efficiently
        members_to_pop =
          if :gb_sets.is_empty(index) do
            []
          else
            take_from_iterator(:gb_sets.iterator(index, :reversed), count, [])
          end

        {new_entries, new_index} =
          Enum.reduce(members_to_pop, {entries, index}, fn {decoded_member, score},
                                                            {acc_entries, acc_index} ->
            new_entries = :gb_trees.delete(decoded_member, acc_entries)
            new_index = :gb_sets.del_element({score, decoded_member}, acc_index)
            {new_entries, new_index}
          end)

        new_store = store_entries(store, db, key, new_entries, new_index)
        {new_store, members_to_pop}
    end
  end

  @doc """
  Computes the union of multiple sorted sets and stores the result.
  Returns the updated store.
  """
  @spec zunionstore(store(), db(), key(), [key()], [float()], aggregate()) :: store()
  def zunionstore(store, db, destination, keys, weights \\ [], aggregate \\ :sum) do
    db_map = Map.get(store, db, %{})
    weights = normalize_weights(keys, weights)

    member_scores =
      keys
      |> Enum.zip(weights)
      |> Enum.flat_map(fn {source_key, weight} ->
        case Map.get(db_map, source_key) do
          nil ->
            []

          %ZSet{entries: entries} ->
            entries
            |> :gb_trees.to_list()
            |> Enum.map(fn {decoded_member, score} -> {decoded_member, score * weight} end)
        end
      end)

    aggregated =
      member_scores
      |> Enum.group_by(fn {decoded_member, _score} -> decoded_member end, fn {_, score} ->
        score
      end)
      |> Enum.map(fn {decoded_member, scores} ->
        final_score = aggregate_scores(scores, aggregate)
        {decoded_member, final_score}
      end)

    # Delete destination first
    store = Vdr.MapProj.Common.del(store, db, destination)

    # Build new entries and index
    {new_entries, new_index} =
      Enum.reduce(aggregated, {:gb_trees.empty(), :gb_sets.new()}, fn {decoded_member, score},
                                                                       {acc_entries, acc_index} ->
        new_entries = :gb_trees.insert(decoded_member, score, acc_entries)
        new_index = :gb_sets.add_element({score, decoded_member}, acc_index)
        {new_entries, new_index}
      end)

    store_entries(store, db, destination, new_entries, new_index)
  end

  @doc """
  Computes the intersection of multiple sorted sets and stores the result.
  Returns the updated store.
  """
  @spec zinterstore(store(), db(), key(), [key()], [float()], aggregate()) :: store()
  def zinterstore(store, db, destination, keys, weights \\ [], aggregate \\ :sum) do
    # Delete destination first
    store = Vdr.MapProj.Common.del(store, db, destination)

    if keys == [] do
      store
    else
      db_map = Map.get(store, db, %{})
      weights = normalize_weights(keys, weights)

      key_members =
        keys
        |> Enum.zip(weights)
        |> Enum.map(fn {source_key, weight} ->
          case Map.get(db_map, source_key) do
            nil ->
              %{}

            %ZSet{entries: entries} ->
              entries
              |> :gb_trees.to_list()
              |> Map.new(fn {decoded_member, score} -> {decoded_member, score * weight} end)
          end
        end)

      [first_map | rest_maps] = key_members

      common_members =
        first_map
        |> Enum.filter(fn {decoded_member, _score} ->
          Enum.all?(rest_maps, fn map -> Map.has_key?(map, decoded_member) end)
        end)
        |> Enum.map(fn {decoded_member, _score} ->
          scores = Enum.map(key_members, fn map -> Map.fetch!(map, decoded_member) end)
          final_score = aggregate_scores(scores, aggregate)
          {decoded_member, final_score}
        end)

      # Build new entries and index
      {new_entries, new_index} =
        Enum.reduce(
          common_members,
          {:gb_trees.empty(), :gb_sets.new()},
          fn {decoded_member, score}, {acc_entries, acc_index} ->
            new_entries = :gb_trees.insert(decoded_member, score, acc_entries)
            new_index = :gb_sets.add_element({score, decoded_member}, acc_index)
            {new_entries, new_index}
          end
        )

      store_entries(store, db, destination, new_entries, new_index)
    end
  end

  @doc """
  Gets the score of a member in a sorted set.
  Returns nil if the member doesn't exist.
  """
  @spec zscore(store(), db(), key(), any()) :: score() | nil
  def zscore(store, db, key, decoded_member) do
    case Map.get(store, db) do
      nil ->
        nil

      db_map ->
        case Map.get(db_map, key) do
          nil ->
            nil

          %ZSet{entries: entries} ->
            case :gb_trees.lookup(decoded_member, entries) do
              :none -> nil
              {:value, score} -> score
            end

          _ ->
            nil
        end
    end
  end

  @doc """
  Returns the number of members in a sorted set.
  """
  @spec zcard(store(), db(), key()) :: non_neg_integer()
  def zcard(store, db, key) do
    case Map.get(store, db) do
      nil ->
        0

      db_map ->
        case Map.get(db_map, key) do
          nil -> 0
          %ZSet{entries: entries} -> :gb_trees.size(entries)
          _ -> 0
        end
    end
  end

  @doc """
  Returns members in a sorted set by rank range.
  Returns a list of {decoded_member, score} tuples.
  """
  @spec zrange(store(), db(), key(), integer(), integer()) :: [{any(), score()}]
  def zrange(store, db, key, start, stop) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        []

      %ZSet{index: index} ->
        # Use iterator to get only the required range
        count = :gb_sets.size(index)
        start_idx = if start < 0, do: max(0, count + start), else: start
        stop_idx = if stop < 0, do: max(-1, count + stop), else: stop

        if stop_idx < start_idx or start_idx >= count do
          []
        else
          take_range_from_iterator(:gb_sets.iterator(index), start_idx, stop_idx)
        end

      _ ->
        []
    end
  end

  @doc """
  Returns members in a sorted set by score range.
  Returns a list of {decoded_member, score} tuples.
  """
  @spec zrangebyscore(
          store(),
          db(),
          key(),
          score() | :neg_inf | :pos_inf,
          score() | :neg_inf | :pos_inf
        ) :: [{any(), score()}]
  def zrangebyscore(store, db, key, min, max) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        []

      %ZSet{index: index} ->
        # Use iterator and filter by score range
        filter_by_score_iterator(:gb_sets.iterator(index), min, max, [])
    end
  end

  @doc """
  Creates a stream of {decoded_member, score} tuples for all sorted set members in score order.
  """
  @spec select_stream(store(), db(), key()) :: Enumerable.t()
  def select_stream(store, db, key) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        []

      %ZSet{index: index} ->
        Stream.resource(
          fn -> :gb_sets.iterator(index) end,
          fn iter ->
            case :gb_sets.next(iter) do
              :none ->
                {:halt, iter}

              {{score, decoded_member}, next_iter} ->
                {[{decoded_member, score}], next_iter}
            end
          end,
          fn _iter -> :ok end
        )
    end
  end

  @doc """
  Creates a reverse stream of {decoded_member, score} tuples for all sorted set members in reverse score order.
  """
  @spec select_rev_stream(store(), db(), key()) :: Enumerable.t()
  def select_rev_stream(store, db, key) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        []

      %ZSet{index: index} ->
        # Use reverse iterator from gb_sets
        Stream.resource(
          fn ->
            if :gb_sets.is_empty(index) do
              :none
            else
              :gb_sets.iterator(index, :reversed)
            end
          end,
          fn
            :none ->
              {:halt, :none}

            iter ->
              case :gb_sets.next(iter) do
                :none ->
                  {:halt, iter}

                {{score, decoded_member}, next_iter} ->
                  {[{decoded_member, score}], next_iter}
              end
          end,
          fn _iter -> :ok end
        )
    end
  end

  # Private helpers

  @spec store_entries(store(), db(), key(), :gb_trees.tree(), :gb_sets.set()) :: store()
  defp store_entries(store, db, key, entries, index) do
    db_map = Map.get(store, db, %{})

    if :gb_trees.size(entries) == 0 do
      # Remove key if empty
      new_db_map = Map.delete(db_map, key)
      Map.put(store, db, new_db_map)
    else
      zset_entry = %ZSet{entries: entries, index: index}
      new_db_map = Map.put(db_map, key, zset_entry)
      Map.put(store, db, new_db_map)
    end
  end

  # Take up to count elements from an iterator, accumulating them in a list
  @spec take_from_iterator(:gb_sets.iter(), non_neg_integer(), [{any(), score()}]) :: [
          {any(), score()}
        ]
  defp take_from_iterator(_iter, 0, acc), do: Enum.reverse(acc)

  defp take_from_iterator(iter, count, acc) do
    case :gb_sets.next(iter) do
      :none ->
        Enum.reverse(acc)

      {{score, decoded_member}, next_iter} ->
        take_from_iterator(next_iter, count - 1, [{decoded_member, score} | acc])
    end
  end

  # Take elements from start_idx to stop_idx (inclusive) from an iterator
  @spec take_range_from_iterator(:gb_sets.iter(), non_neg_integer(), non_neg_integer()) :: [
          {any(), score()}
        ]
  defp take_range_from_iterator(iter, start_idx, stop_idx) do
    # Skip to start_idx
    iter = skip_iterator(iter, start_idx)
    # Take (stop_idx - start_idx + 1) elements
    count = stop_idx - start_idx + 1
    take_from_iterator(iter, count, [])
  end

  # Skip n elements in an iterator
  @spec skip_iterator(:gb_sets.iter(), non_neg_integer()) :: :gb_sets.iter()
  defp skip_iterator(iter, 0), do: iter

  defp skip_iterator(iter, n) do
    case :gb_sets.next(iter) do
      :none -> iter
      {_elem, next_iter} -> skip_iterator(next_iter, n - 1)
    end
  end

  # Filter elements by score range using an iterator
  @spec filter_by_score_iterator(
          :gb_sets.iter(),
          score() | :neg_inf | :pos_inf,
          score() | :neg_inf | :pos_inf,
          [{any(), score()}]
        ) :: [{any(), score()}]
  defp filter_by_score_iterator(iter, min, max, acc) do
    case :gb_sets.next(iter) do
      :none ->
        Enum.reverse(acc)

      {{score, decoded_member}, next_iter} ->
        new_acc =
          if score_in_range?(score, min, max) do
            [{decoded_member, score} | acc]
          else
            acc
          end

        filter_by_score_iterator(next_iter, min, max, new_acc)
    end
  end

  # Filter elements by lex range using an iterator
  @spec filter_by_lex_iterator(:gb_sets.iter(), any(), any(), [{any(), score()}]) :: [
          {any(), score()}
        ]
  defp filter_by_lex_iterator(iter, min, max, acc) do
    case :gb_sets.next(iter) do
      :none ->
        Enum.reverse(acc)

      {{score, decoded_member}, next_iter} ->
        new_acc =
          if lex_in_range?(decoded_member, min, max) do
            [{decoded_member, score} | acc]
          else
            acc
          end

        filter_by_lex_iterator(next_iter, min, max, new_acc)
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
