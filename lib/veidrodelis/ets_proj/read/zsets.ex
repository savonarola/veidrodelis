defmodule Vdr.ETSProj.Read.ZSets do
  @moduledoc """
  Read operations for Redis sorted set (zset) store.

  Reads already-decoded data from ETS.
  """

  defstruct [:tid]

  @type t :: %__MODULE__{
          tid: :ets.tid()
        }

  @type db :: non_neg_integer()
  @type key :: any()
  @type score :: float()

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
  Returns members in a sorted set by score order.
  Returns a list of {decoded_value, score} tuples.
  """
  @spec zrange(t(), db(), key(), integer(), integer()) :: [{any(), score()}]
  def zrange(%__MODULE__{tid: tid}, db, key, start, stop) do
    zrange_with_scores(tid, db, key, start, stop)
  end

  @doc """
  Returns members in a sorted set by score range.
  Returns a list of {decoded_value, score} tuples.
  """
  @spec zrangebyscore(
          t(),
          db(),
          key(),
          score() | :neg_inf | :pos_inf,
          score() | :neg_inf | :pos_inf
        ) :: [{any(), score()}]
  def zrangebyscore(%__MODULE__{tid: tid}, db, key, min, max) do
    match_head = {{db, key, :zset_index, {:"$1", :"$2"}}, :_}
    match_spec = [{match_head, [], [{{:"$2", :"$1"}}]}]

    :ets.select(tid, match_spec)
    |> Enum.filter(fn {_decoded_value, score} ->
      score_in_range?(score, min, max)
    end)
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
end
