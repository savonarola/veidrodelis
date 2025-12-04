defmodule Vdr.ETSProj.Read.Lists do
  @moduledoc """
  Read operations for Redis list store.

  Reads already-decoded data from ETS.
  Uses streaming operations for efficient access to list data.
  All public APIs use 0-based indexing.
  """

  require Logger
  alias VDR.ETSRead

  defstruct [:tid]

  @type t :: %__MODULE__{
          tid: :ets.tid()
        }

  @type db :: non_neg_integer()
  @type key :: any()
  @type entry_match_pattern :: {pattern :: term(), guards :: list()}

  @doc """
  Creates a new list read store with the given ETS table.
  """
  @spec new(:ets.tid()) :: t()
  def new(tid) do
    %__MODULE__{tid: tid}
  end

  @doc """
  Creates a stream of {0-based-index, entry} tuples for a range of list elements.
  Indices are inclusive. Negative indices are supported.
  """
  @spec range_stream(t(), db(), key(), integer(), integer()) :: Enumerable.t()
  def range_stream(store, db, key, from, to) do
    range_stream_impl(store, db, key, from, to, false)
  end

  @doc """
  Creates a reverse stream of {0-based-index, entry} tuples for a range of list elements.
  Indices are inclusive. Negative indices are supported.
  """
  @spec range_rev_stream(t(), db(), key(), integer(), integer()) :: Enumerable.t()
  def range_rev_stream(store, db, key, from, to) do
    range_stream_impl(store, db, key, from, to, true)
  end

  @doc """
  Creates a stream of {0-based-index, entry} tuples for all list elements.
  """
  @spec stream(t(), db(), key()) :: Enumerable.t()
  def stream(%__MODULE__{tid: tid}, db, key) do
    case first_idx(tid, db, key) do
      nil ->
        Stream.map([], fn _ -> nil end)

      first_idx ->
        tid
        |> ETSRead.match_stream({{db, key, :list, :"$1"}, :"$2"}, 100)
        |> Stream.map(fn [idx, entry] -> {idx - first_idx, entry} end)
    end
  end

  @doc """
  Creates a stream of {0-based-index, entry} tuples matching the entry pattern.

  The pattern is a simplified match spec tuple: `{head_pattern, guards}` that matches against
  the entry value only.

  Example: `{:"$_", [{:==, :"$_", "value"}]}` matches entries equal to "value"
  """
  @spec select_stream(t(), db(), key(), entry_match_pattern()) :: Enumerable.t()
  def select_stream(%__MODULE__{tid: tid}, db, key, {head, guards}) do
    first = first_idx(tid, db, key)

    if is_integer(first) do
      # Build full match spec that wraps the head pattern
      # Pattern: {{{db, key, :list, '_'}, head}, guards, '$_'}
      full_match_spec = [{{{db, key, :list, :_}, head}, guards, [:"$_"]}]

      tid
      |> ETSRead.select_stream(full_match_spec, 100)
      |> Stream.map(fn {{_db, _key, :list, idx}, entry} ->
        {idx - first, entry}
      end)
    else
      Stream.map([], fn _ -> nil end)
    end
  end

  @doc """
  Creates a reverse stream of {0-based-index, entry} tuples matching the entry pattern.

  The pattern is a simplified match spec tuple: `{head_pattern, guards}` that matches against
  the entry value only.
  """
  @spec select_rev_stream(t(), db(), key(), entry_match_pattern()) :: Enumerable.t()
  def select_rev_stream(%__MODULE__{tid: tid}, db, key, {head, guards}) do
    first = first_idx(tid, db, key)

    if is_integer(first) do
      # Build full match spec that wraps the head pattern
      full_match_spec = [{{{db, key, :list, :_}, head}, guards, [:"$_"]}]

      tid
      |> ETSRead.select_rev_stream(full_match_spec, 100)
      |> Stream.map(fn {{_db, _key, :list, idx}, entry} ->
        {idx - first, entry}
      end)
    else
      Stream.map([], fn _ -> nil end)
    end
  end

  @doc """
  Get a range of elements from the list.
  Both start and stop are inclusive and support negative indices.
  Returns decoded values.
  """
  @spec lrange(t(), db(), key(), integer(), integer()) :: [any()]
  def lrange(store, db, key, start_idx, stop_idx) do
    store
    |> range_stream(db, key, start_idx, stop_idx)
    |> Stream.map(fn {_idx, entry} -> entry end)
    |> Enum.to_list()
  end

  @doc """
  Returns the length of the list.
  Efficiently computed as max(0, (last_idx - first_idx + 1)).
  """
  @spec llen(t(), db(), key()) :: non_neg_integer()
  def llen(%__MODULE__{tid: tid}, db, key) do
    case {first_idx(tid, db, key), last_idx(tid, db, key)} do
      {nil, nil} -> 0
      {first, last} when is_integer(first) and is_integer(last) -> max(0, last - first + 1)
    end
  end

  # Private helpers

  # Get the first (minimum) actual ETS index for a list
  @spec first_idx(:ets.tid(), db(), key()) :: integer() | nil
  defp first_idx(tid, db, key) do
    case ETSRead.first_key(tid, {{db, key, :list, :_}, :_}) do
      nil -> nil
      {_db, _key, :list, idx} -> idx
    end
  end

  # Get the last (maximum) actual ETS index for a list
  @spec last_idx(:ets.tid(), db(), key()) :: integer() | nil
  defp last_idx(tid, db, key) do
    case ETSRead.last_key(tid, {{db, key, :list, :_}, :_}) do
      nil -> nil
      {_db, _key, :list, idx} -> idx
    end
  end

  # Implementation for range_stream and range_rev_stream
  @spec range_stream_impl(t(), db(), key(), integer(), integer(), boolean()) ::
          Enumerable.t()
  defp range_stream_impl(%__MODULE__{tid: tid}, db, key, from, to, reverse?) do
    first = first_idx(tid, db, key)
    last = last_idx(tid, db, key)

    # Check that both indices are integers and first <= last
    if is_integer(first) and is_integer(last) and first <= last do
      len = last - first + 1

      # Normalize indices (handle negative indices)
      start_pos = normalize_index(from, len)
      stop_pos = normalize_index(to, len)

      # Return empty if range is invalid
      if start_pos > stop_pos or start_pos >= len do
        Stream.map([], fn _ -> nil end)
      else
        # Clamp stop_pos to list length
        stop_pos = min(stop_pos, len - 1)

        # Convert 0-based positions to actual ETS indices
        actual_start = first + start_pos
        actual_stop = first + stop_pos

        # Stream the range
        stream =
          if reverse? do
            ETSRead.key_rev_range_stream(
              tid,
              {db, key, :list, actual_stop},
              {db, key, :list, actual_start}
            )
          else
            ETSRead.key_range_stream(
              tid,
              {db, key, :list, actual_start},
              {db, key, :list, actual_stop}
            )
          end

        stream
        |> Stream.map(fn {{_db, _key, :list, idx}, entry} ->
          {idx - first, entry}
        end)
      end
    else
      # Empty list or invalid state
      Stream.map([], fn _ -> nil end)
    end
  end

  @spec normalize_index(integer(), non_neg_integer()) :: non_neg_integer()
  defp normalize_index(idx, len) when idx < 0 do
    max(0, len + idx)
  end

  defp normalize_index(idx, _len) do
    max(0, idx)
  end
end
