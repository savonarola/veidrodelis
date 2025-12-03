defmodule Vdr.ETSProj.Read.Lists do
  @moduledoc """
  Read operations for Redis list store.

  Reads already-decoded data from ETS.
  """

  require Logger

  defstruct [:tid]

  @type t :: %__MODULE__{
          tid: :ets.tid()
        }

  @type db :: non_neg_integer()
  @type key :: any()

  @doc """
  Creates a new list read store with the given ETS table.
  """
  @spec new(:ets.tid()) :: t()
  def new(tid) do
    %__MODULE__{tid: tid}
  end

  @doc """
  Get a range of elements from the list.
  Both start and stop are inclusive and support negative indices.
  Returns decoded values.
  """
  @spec lrange(t(), db(), key(), integer(), integer()) :: [any()]
  def lrange(%__MODULE__{tid: tid}, db, key, start_idx, stop_idx) do
    entries = fetch_all_entries_sorted(tid, db, key)
    len = length(entries)

    start_pos = normalize_index(start_idx, len)
    stop_pos = normalize_index(stop_idx, len)
    Logger.debug("lrange: #{inspect(entries)}, start_pos: #{inspect(start_pos)}, stop_pos: #{inspect(stop_pos)}")

    if start_pos > stop_pos or start_pos >= len do
      []
    else
      entries
      |> Enum.slice(start_pos..min(stop_pos, len - 1))
      |> Enum.map(fn {_idx, decoded} -> decoded end)
    end
  end

  @doc """
  Returns the length of the list.
  """
  @spec llen(t(), db(), key()) :: non_neg_integer()
  def llen(%__MODULE__{tid: tid}, db, key) do
    match_spec = [
      {{{db, key, :list, :_}, :_}, [], [true]}
    ]

    :ets.select_count(tid, match_spec)
  end

  # Private helpers

  @spec fetch_all_entries_sorted(:ets.tid(), db(), key()) :: [{integer(), any()}]
  defp fetch_all_entries_sorted(tid, db, key) do
    match_spec = [
      {{{db, key, :list, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}
    ]

    tid
    |> :ets.select(match_spec)
    |> Enum.sort_by(fn {idx, _decoded} -> idx end)
  end

  @spec normalize_index(integer(), non_neg_integer()) :: non_neg_integer()
  defp normalize_index(idx, len) when idx < 0 do
    max(0, len + idx)
  end

  defp normalize_index(idx, _len) do
    max(0, idx)
  end
end
