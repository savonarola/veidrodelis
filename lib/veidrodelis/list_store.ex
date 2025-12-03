defmodule Vdr.ListStore do
  @moduledoc """
  An ETS-backed store for Redis list operations.

  Uses a shared ETS table to store list elements with integer indices.
  Each entry is stored as `{{db, key, :list, idx}, decoded_entry}`.

  The list maintains a consecutive integer index invariant, though indices
  are not necessarily positive. Elements can be pushed/popped from both ends,
  and the indices adjust accordingly:
  - LPUSH decrements the minimum index
  - RPUSH increments the maximum index
  - LPOP removes the minimum index
  - RPOP removes the maximum index

  The decode function is called for each element to compute a decoded representation.
  """

  require Logger

  alias Vdr.CommonStore

  defstruct [:tid, :decode_fun]

  @type t :: %__MODULE__{
          tid: :ets.tid(),
          decode_fun: decode_fun()
        }

  @type db :: non_neg_integer()
  @type key :: any()
  @type element :: binary()
  @type decode_fun :: (key(), element() -> any())
  @type position :: :before | :after

  @doc """
  Creates a new list store with the given ETS table and decode function.

  The decode function receives `(key, element)` and returns a decoded value
  that will be stored in the ETS value.

  Returns a ListStore struct containing the table id and decode function.
  """
  @spec new(:ets.tid(), decode_fun()) :: t()
  def new(tid, decode_fun) when is_function(decode_fun, 2) do
    %__MODULE__{tid: tid, decode_fun: decode_fun}
  end

  @doc """
  Insert all values at the head of the list (left side).
  Elements are inserted one after the other, so LPUSH key "a" "b" "c"
  results in ["c", "b", "a"] being prepended.
  """
  @spec lpush(t(), db(), key(), [element()]) :: :ok
  def lpush(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, values)
      when is_list(values) do
    # Find the current minimum index
    min_idx = find_min_index(tid, db, key)

    Logger.debug("lpush: #{inspect(values)} #{inspect(min_idx)}")

    # Insert elements with decreasing indices
    values
    |> Enum.reverse()
    |> Enum.with_index(min_idx - length(values))
    |> Enum.each(fn {value, idx} ->
      decoded = decode_fun.(key, value)
      Logger.debug("insert: #{inspect({db, key, :list, idx})}: #{inspect(decoded)}")
      :ets.insert(tid, {{db, key, :list, idx}, decoded})
    end)

    :ok
  end

  @doc """
  Insert all values at the tail of the list (right side).
  Elements are inserted in order.
  """
  @spec rpush(t(), db(), key(), [element()]) :: :ok
  def rpush(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, values)
      when is_list(values) do
    # Find the current maximum index
    max_idx = find_max_index(tid, db, key)

    # Insert elements with increasing indices
    values
    |> Enum.with_index(max_idx + 1)
    |> Enum.each(fn {value, idx} ->
      decoded = decode_fun.(key, value)
      :ets.insert(tid, {{db, key, :list, idx}, decoded})
    end)

    :ok
  end

  @doc """
  Insert values at the head, only if the key exists.
  """
  @spec lpushx(t(), db(), key(), [element()]) :: :ok
  def lpushx(%__MODULE__{tid: tid} = store, db, key, values) when is_list(values) do
    # Check if key exists by checking if there's at least one element
    case list_exists?(tid, db, key) do
      true -> lpush(store, db, key, values)
      false -> :ok
    end
  end

  @doc """
  Insert values at the tail, only if the key exists.
  """
  @spec rpushx(t(), db(), key(), [element()]) :: :ok
  def rpushx(%__MODULE__{tid: tid} = store, db, key, values) when is_list(values) do
    case list_exists?(tid, db, key) do
      true -> rpush(store, db, key, values)
      false -> :ok
    end
  end

  @doc """
  Remove and return the first element of the list (from the head).
  """
  @spec lpop(t(), db(), key()) :: :ok
  def lpop(%__MODULE__{tid: tid}, db, key) do
    case find_min_index_entry(tid, db, key) do
      nil ->
        :ok

      {idx, _decoded} ->
        :ets.delete(tid, {db, key, :list, idx})
        :ok
    end
  end

  @doc """
  Remove and return the last element of the list (from the tail).
  """
  @spec rpop(t(), db(), key()) :: :ok
  def rpop(%__MODULE__{tid: tid}, db, key) do
    case find_max_index_entry(tid, db, key) do
      nil ->
        :ok

      {idx, _decoded} ->
        :ets.delete(tid, {db, key, :list, idx})
        :ok
    end
  end

  @doc """
  Remove the first count occurrences of element from the list.
  - count > 0: Remove elements from head to tail
  - count < 0: Remove elements from tail to head
  - count = 0: Remove all occurrences
  """
  @spec lrem(t(), db(), key(), integer(), element()) :: :ok
  def lrem(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, count, element) do
    decoded_element = decode_fun.(key, element)
    entries = fetch_all_entries_sorted(tid, db, key)

    entries_to_remove =
      cond do
        count > 0 ->
          # From head to tail
          entries
          |> Enum.filter(fn {_idx, decoded} -> decoded == decoded_element end)
          |> Enum.take(count)

        count < 0 ->
          # From tail to head
          entries
          |> Enum.reverse()
          |> Enum.filter(fn {_idx, decoded} -> decoded == decoded_element end)
          |> Enum.take(abs(count))

        count == 0 ->
          # All occurrences
          entries
          |> Enum.filter(fn {_idx, decoded} -> decoded == decoded_element end)
      end

    # Delete the selected entries
    Enum.each(entries_to_remove, fn {idx, _decoded} ->
      :ets.delete(tid, {db, key, :list, idx})
    end)

    :ok
  end

  @doc """
  Trim the list to the specified range.
  Both start and stop are inclusive and support negative indices.
  """
  @spec ltrim(t(), db(), key(), integer(), integer()) :: :ok
  def ltrim(%__MODULE__{tid: tid}, db, key, start_idx, stop_idx) do
    entries = fetch_all_entries_sorted(tid, db, key)
    len = length(entries)

    # Normalize indices
    start_pos = normalize_index(start_idx, len)
    stop_pos = normalize_index(stop_idx, len)

    # Determine which entries to keep
    entries_to_keep =
      if start_pos > stop_pos or start_pos >= len do
        []
      else
        Enum.slice(entries, start_pos..min(stop_pos, len - 1))
      end

    kept_indices = MapSet.new(entries_to_keep, fn {idx, _decoded} -> idx end)

    # Delete entries not in the keep list
    Enum.each(entries, fn {idx, _decoded} ->
      if not MapSet.member?(kept_indices, idx) do
        :ets.delete(tid, {db, key, :list, idx})
      end
    end)

    :ok
  end

  @doc """
  Set the list element at index to value.
  Supports negative indices.
  """
  @spec lset(t(), db(), key(), integer(), element()) :: :ok
  def lset(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, index, value) do
    entries = fetch_all_entries_sorted(tid, db, key)
    len = length(entries)

    pos = if index < 0, do: len + index, else: index

    if pos >= 0 and pos < len do
      {actual_idx, _old_decoded} = Enum.at(entries, pos)
      decoded = decode_fun.(key, value)
      :ets.insert(tid, {{db, key, :list, actual_idx}, decoded})
    end

    :ok
  end

  @doc """
  Insert value before or after the pivot element.
  Position must be :before or :after.
  """
  @spec linsert(t(), db(), key(), position(), element(), element()) :: :ok
  def linsert(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, position, pivot, value)
      when position in [:before, :after] do
    decoded_pivot = decode_fun.(key, pivot)
    entries = fetch_all_entries_sorted(tid, db, key)

    # Find the pivot
    case Enum.find_index(entries, fn {_idx, decoded} -> decoded == decoded_pivot end) do
      nil ->
        :ok

      pivot_pos ->
        decoded_value = decode_fun.(key, value)

        # We need to insert at a specific position while maintaining consecutive indices
        # Strategy: renumber all indices starting from 0 and insert the new element
        new_insert_pos = if position == :before, do: pivot_pos, else: pivot_pos + 1

        # Delete all existing entries
        Enum.each(entries, fn {idx, _decoded} ->
          :ets.delete(tid, {db, key, :list, idx})
        end)

        # Re-insert with new indices
        entries
        |> Enum.with_index()
        |> Enum.each(fn {{_old_idx, decoded}, new_pos} ->
          final_pos = if new_pos >= new_insert_pos, do: new_pos + 1, else: new_pos
          :ets.insert(tid, {{db, key, :list, final_pos}, decoded})
        end)

        # Insert the new value
        :ets.insert(tid, {{db, key, :list, new_insert_pos}, decoded_value})

        :ok
    end
  end

  @doc """
  Atomically pop the last element from source and push it to the head of dest.
  """
  @spec rpoplpush(t(), db(), key(), key()) :: :ok
  def rpoplpush(%__MODULE__{tid: tid}, db, source, dest) do
    case find_max_index_entry(tid, db, source) do
      nil ->
        :ok

      {source_idx, popped_value} ->
        # Remove from source
        :ets.delete(tid, {db, source, :list, source_idx})

        # Add to destination head
        dest_min_idx = find_min_index(tid, db, dest)
        :ets.insert(tid, {{db, dest, :list, dest_min_idx - 1}, popped_value})

        :ok
    end
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

  @doc """
  Deletes an entire list.
  """
  @spec del(t(), db(), key()) :: :ok
  def del(%__MODULE__{tid: tid}, db, key) do
    CommonStore.del(tid, db, key)
  end

  # Private helpers

  @spec list_exists?(:ets.tid(), db(), key()) :: boolean()
  defp list_exists?(tid, db, key) do
    match_spec = [
      {{{db, key, :list, :_}, :_}, [], [true]}
    ]

    :ets.select_count(tid, match_spec) > 0
  end

  @spec find_min_index(:ets.tid(), db(), key()) :: integer()
  defp find_min_index(tid, db, key) do
    case find_min_index_entry(tid, db, key) do
      nil -> 0
      {idx, _decoded} -> idx
    end
  end

  @spec find_max_index(:ets.tid(), db(), key()) :: integer()
  defp find_max_index(tid, db, key) do
    case find_max_index_entry(tid, db, key) do
      nil -> -1
      {idx, _decoded} -> idx
    end
  end

  @spec find_min_index_entry(:ets.tid(), db(), key()) :: {integer(), any()} | nil
  defp find_min_index_entry(tid, db, key) do
    match_spec = [
      {{{db, key, :list, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}
    ]

    case :ets.select(tid, match_spec) do
      [] -> nil
      entries -> Enum.min_by(entries, fn {idx, _decoded} -> idx end)
    end
  end

  @spec find_max_index_entry(:ets.tid(), db(), key()) :: {integer(), any()} | nil
  defp find_max_index_entry(tid, db, key) do
    match_spec = [
      {{{db, key, :list, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}
    ]

    case :ets.select(tid, match_spec) do
      [] -> nil
      entries -> Enum.max_by(entries, fn {idx, _decoded} -> idx end)
    end
  end

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
