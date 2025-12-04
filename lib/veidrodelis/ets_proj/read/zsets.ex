defmodule Vdr.ETSProj.Read.ZSets do
  @moduledoc """
  Read operations for Redis sorted set (zset) store.

  Reads already-decoded data from ETS.
  """

  alias VDR.ETSRead

  defstruct [:tid]

  @type t :: %__MODULE__{
          tid: :ets.tid()
        }

  @type db :: non_neg_integer()
  @type key :: any()
  @type score :: float()
  @type entry_match_pattern :: {pattern :: term(), guards :: list()}

  @doc """
  Creates a new zset read store with the given ETS table.
  """
  @spec new(:ets.tid()) :: t()
  def new(tid) do
    %__MODULE__{tid: tid}
  end

  @doc """
  Gets the score of a member in a sorted set.
  Note: This requires the decoded member value.
  """
  @spec zscore(t(), db(), key(), any()) :: score() | nil
  def zscore(%__MODULE__{tid: tid}, db, key, decoded_member) do
    case :ets.lookup(tid, {db, key, :zset, decoded_member}) do
      [] -> nil
      [{_, score}] -> score
    end
  end

  @doc """
  Returns the number of members in a sorted set.
  """
  @spec zcard(t(), db(), key()) :: non_neg_integer()
  def zcard(%__MODULE__{tid: tid}, db, key) do
    match_spec = [
      {{{db, key, :zset, :_}, :_}, [], [true]}
    ]

    :ets.select_count(tid, match_spec)
  end

  @doc """
  Creates a stream of {entry, score} tuples for all sorted set members in score order.

  Uses the :zset_index entries which are ordered by score.
  Returns tuples of {decoded_entry, score}.
  """
  @spec select_stream(t(), db(), key()) :: Enumerable.t()
  def select_stream(%__MODULE__{tid: tid}, db, key) do
    # Match all :zset_index entries for this key
    # Pattern: {{db, key, :zset_index, {score, entry}}, nil}
    # Return: {entry, score}
    match_spec = [
      {{{db, key, :zset_index, {:"$1", :"$2"}}, :_}, [], [{{:"$2", :"$1"}}]}
    ]

    ETSRead.select_stream(tid, match_spec, 100)
  end

  @doc """
  Creates a reverse stream of {entry, score} tuples for all sorted set members in reverse score order.

  Uses the :zset_index entries which are ordered by score.
  Returns tuples of {decoded_entry, score} in reverse order.
  """
  @spec select_rev_stream(t(), db(), key()) :: Enumerable.t()
  def select_rev_stream(%__MODULE__{tid: tid}, db, key) do
    # Match all :zset_index entries for this key in reverse order
    match_spec = [
      {{{db, key, :zset_index, {:"$1", :"$2"}}, :_}, [], [{{:"$2", :"$1"}}]}
    ]

    ETSRead.select_rev_stream(tid, match_spec, 100)
  end

  @doc """
  Creates a stream of {entry, score} tuples for sorted set members within a score range.

  Returns tuples of {decoded_entry, score} where score is between from_score and to_score (inclusive).
  Members are returned in ascending score order.
  """
  @spec range_stream(t(), db(), key(), number(), number()) :: Enumerable.t()
  def range_stream(%__MODULE__{tid: tid}, db, key, from_score, to_score)
      when is_number(from_score) and is_number(to_score) do
    case find_range_boundaries(tid, db, key, from_score, to_score) do
      nil ->
        # Empty range
        Stream.map([], fn _ -> nil end)

      {first_key, last_key} ->
        tid
        |> ETSRead.key_range_stream(first_key, last_key)
        |> Stream.map(fn {{_db, _key, :zset_index, {score, entry}}, _} ->
          {entry, score}
        end)
    end
  end

  @doc """
  Creates a reverse stream of {entry, score} tuples for sorted set members within a score range.

  Returns tuples of {decoded_entry, score} where score is between from_score and to_score (inclusive).
  Members are returned in descending score order.
  """
  @spec range_rev_stream(t(), db(), key(), number(), number()) :: Enumerable.t()
  def range_rev_stream(%__MODULE__{tid: tid}, db, key, from_score, to_score)
      when is_number(from_score) and is_number(to_score) do
    case find_range_boundaries(tid, db, key, from_score, to_score) do
      nil ->
        # Empty range
        Stream.map([], fn _ -> nil end)

      {first_key, last_key} ->
        tid
        |> ETSRead.key_rev_range_stream(last_key, first_key)
        |> Stream.map(fn {{_db, _key, :zset_index, {score, entry}}, _} ->
          {entry, score}
        end)
    end
  end

  @doc """
  Returns members in a sorted set by score range.
  Returns a list of {decoded_value, score} tuples.
  """
  @spec zrange(t(), db(), key(), number(), number()) :: [{any(), score()}]
  def zrange(store, db, key, start, stop)
      when is_number(start) and is_number(stop) do
    zrange_with_scores(store, db, key, start, stop)
  end

  @doc """
  Returns members in a sorted set by score range.
  Returns a list of {decoded_value, score} tuples.
  """
  @spec zrangebyscore(t(), db(), key(), number(), number()) :: [{any(), score()}]
  def zrangebyscore(store, db, key, min, max) when is_number(min) and is_number(max) do
    # Use efficient range_stream for score bounds
    store
    |> range_stream(db, key, min, max)
    |> Enum.to_list()
  end

  # Private helpers

  @spec zrange_with_scores(t(), db(), key(), number(), number()) :: [{any(), score()}]
  defp zrange_with_scores(store, db, key, start, stop)
       when is_number(start) and is_number(stop) do
    # start and stop are scores (numbers)
    # Use range_stream
    store
    |> range_stream(db, key, start, stop)
    |> Enum.to_list()
  end

  @spec find_range_boundaries(:ets.tid(), db(), key(), number(), number()) ::
          {tuple(), tuple()} | nil
  defp find_range_boundaries(tid, db, key, from_score, to_score) do
    # Find the first key >= {db, key, :zset_index, {from_score, _}}
    first_key =
      case ETSRead.first_key(tid, {{db, key, :zset_index, {from_score, :_}}, :_}) do
        nil ->
          # No exact match for from_score, find next key after this score
          # Use a minimal term "" to find the next entry
          case :ets.next(tid, {db, key, :zset_index, {from_score, -1.0e99}}) do
            :"$end_of_table" ->
              nil

            next_key ->
              # Verify it's still in our key space and within range
              case next_key do
                {^db, ^key, :zset_index, {score, _entry}} when score <= to_score ->
                  next_key

                _ ->
                  nil
              end
          end

        key ->
          key
      end

    # Find the last key <= {db, key, :zset_index, {to_score, _}}
    last_key =
      case ETSRead.last_key(tid, {{db, key, :zset_index, {to_score, :_}}, :_}) do
        nil ->
          # No exact match for to_score, find previous key before this score
          # Use a large term to find the previous entry
          # In Erlang term ordering, atoms come after most other terms
          case :ets.prev(tid, {db, key, :zset_index, {to_score, <<255>>}}) do
            :"$end_of_table" ->
              nil

            prev_key ->
              # Verify it's still in our key space and within range
              case prev_key do
                {^db, ^key, :zset_index, {score, _entry}} when score >= from_score ->
                  prev_key

                _ ->
                  nil
              end
          end

        key ->
          key
      end

    # Return nil if either boundary is missing
    case {first_key, last_key} do
      {nil, _} -> nil
      {_, nil} -> nil
      {first, last} when first <= last -> {first, last}
      _ -> nil
    end
  end

end
