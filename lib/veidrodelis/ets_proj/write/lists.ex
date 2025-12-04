defmodule Vdr.ETSProj.Write.Lists do
  @moduledoc """
  Write operations for Redis list store.

  Uses a shared ETS table to store list elements with integer indices.
  Each entry is stored as `{{db, key, :list, idx}, decoded_entry}`.
  """

  require Logger
  alias VDR.ETSRead

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
  """
  @spec new(:ets.tid(), decode_fun()) :: t()
  def new(tid, decode_fun) when is_function(decode_fun, 2) do
    %__MODULE__{tid: tid, decode_fun: decode_fun}
  end

  @doc """
  Insert all values at the head of the list (left side).
  """
  @spec lpush(t(), db(), key(), [element()]) :: :ok
  def lpush(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, values)
      when is_list(values) do
    min_idx = find_min_index(tid, db, key)

    Logger.debug("lpush: #{inspect(values)} #{inspect(min_idx)}")

    # Batch insert all values at once
    entries =
      values
      |> Enum.reverse()
      |> Enum.with_index(min_idx - length(values))
      |> Enum.map(fn {value, idx} ->
        decoded = decode_fun.(key, value)
        Logger.debug("insert: #{inspect({db, key, :list, idx})}: #{inspect(decoded)}")
        {{db, key, :list, idx}, decoded}
      end)

    :ets.insert(tid, entries)
    :ok
  end

  @doc """
  Insert all values at the tail of the list (right side).
  """
  @spec rpush(t(), db(), key(), [element()]) :: :ok
  def rpush(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, values)
      when is_list(values) do
    max_idx = find_max_index(tid, db, key)

    # Batch insert all values at once
    entries =
      values
      |> Enum.with_index(max_idx + 1)
      |> Enum.map(fn {value, idx} ->
        decoded = decode_fun.(key, value)
        {{db, key, :list, idx}, decoded}
      end)

    :ets.insert(tid, entries)
    :ok
  end

  @doc """
  Insert values at the head, only if the key exists.
  """
  @spec lpushx(t(), db(), key(), [element()]) :: :ok
  def lpushx(%__MODULE__{tid: tid} = store, db, key, values) when is_list(values) do
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
  """
  @spec lrem(t(), db(), key(), integer(), element()) :: :ok
  def lrem(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, count, element) do
    decoded_element = decode_fun.(key, element)
    match_spec = [
      {{{db, key, :list, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}
    ]

    # Step 1: Stream through entries and delete matching ones on-the-fly
    deleted_count =
      cond do
        count > 0 ->
          # Stream forward, filter matching, take count, delete on-the-fly
          tid
          |> :ets.select(match_spec)
          |> Stream.filter(fn {_idx, decoded} -> decoded == decoded_element end)
          |> Stream.take(count)
          |> Enum.reduce(0, fn {idx, _decoded}, acc ->
            :ets.delete(tid, {db, key, :list, idx})
            acc + 1
          end)

        count < 0 ->
          # Stream backward, filter matching, take abs(count), delete on-the-fly
          case :ets.select_reverse(tid, match_spec, 100) do
            :"$end_of_table" ->
              0

            {results, continuation} ->
              Stream.resource(
                fn -> {results, continuation} end,
                fn
                  :"$end_of_table" -> {:halt, nil}
                  {results, cont} -> {results, :ets.select_reverse(cont)}
                end,
                fn _ -> :ok end
              )
              |> Stream.filter(fn {_idx, decoded} -> decoded == decoded_element end)
              |> Stream.take(abs(count))
              |> Enum.reduce(0, fn {idx, _decoded}, acc ->
                :ets.delete(tid, {db, key, :list, idx})
                acc + 1
              end)
          end

        count == 0 ->
          # Stream all, filter matching, delete on-the-fly
          tid
          |> :ets.select(match_spec)
          |> Stream.filter(fn {_idx, decoded} -> decoded == decoded_element end)
          |> Enum.reduce(0, fn {idx, _decoded}, acc ->
            :ets.delete(tid, {db, key, :list, idx})
            acc + 1
          end)
      end

    # Step 2: Re-enumerate remaining elements if any were deleted
    if deleted_count > 0 do
      # Step 3: Stream through remaining entries and update indices on-the-fly
      # Zip with expected indices starting from min_idx (min_idx, min_idx+1, min_idx+2, ...)
      case find_min_index_entry(tid, db, key) do
        nil ->
          :ok

        {min_idx, _} ->
          # Stream through entries in order using ETSRead, zip with expected indices starting from min_idx
          # Update only entries where actual_idx != expected_idx
          ETSRead.select_stream(tid, match_spec, 100)
          |> Stream.with_index(min_idx)
          |> Enum.each(fn {{actual_idx, decoded}, expected_idx} ->
            if actual_idx != expected_idx do
              :ets.delete(tid, {db, key, :list, actual_idx})
              :ets.insert(tid, {{db, key, :list, expected_idx}, decoded})
            end
          end)
      end
    end

    :ok
  end

  @doc """
  Trim the list to the specified range.
  """
  @spec ltrim(t(), db(), key(), integer(), integer()) :: :ok
  def ltrim(%__MODULE__{tid: tid}, db, key, start_idx, stop_idx) do
    entries = fetch_all_entries_sorted(tid, db, key)
    len = length(entries)

    start_pos = normalize_index(start_idx, len)
    stop_pos = normalize_index(stop_idx, len)

    entries_to_keep =
      if start_pos > stop_pos or start_pos >= len do
        []
      else
        Enum.slice(entries, start_pos..min(stop_pos, len - 1))
      end

    kept_indices = MapSet.new(entries_to_keep, fn {idx, _decoded} -> idx end)

    Enum.each(entries, fn {idx, _decoded} ->
      if not MapSet.member?(kept_indices, idx) do
        :ets.delete(tid, {db, key, :list, idx})
      end
    end)

    :ok
  end

  @doc """
  Set the list element at index to value.
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
  """
  @spec linsert(t(), db(), key(), position(), element(), element()) :: :ok
  def linsert(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, position, pivot, value)
      when position in [:before, :after] do
    decoded_pivot = decode_fun.(key, pivot)
    entries = fetch_all_entries_sorted(tid, db, key)

    case Enum.find_index(entries, fn {_idx, decoded} -> decoded == decoded_pivot end) do
      nil ->
        :ok

      pivot_pos ->
        decoded_value = decode_fun.(key, value)

        new_insert_pos = if position == :before, do: pivot_pos, else: pivot_pos + 1

        # Delete all old entries
        Enum.each(entries, fn {idx, _decoded} ->
          :ets.delete(tid, {db, key, :list, idx})
        end)

        # Batch insert all reindexed entries plus the new value
        reindexed_entries =
          entries
          |> Enum.with_index()
          |> Enum.map(fn {{_old_idx, decoded}, new_pos} ->
            final_pos = if new_pos >= new_insert_pos, do: new_pos + 1, else: new_pos
            {{db, key, :list, final_pos}, decoded}
          end)

        all_entries = [{{db, key, :list, new_insert_pos}, decoded_value} | reindexed_entries]
        :ets.insert(tid, all_entries)

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
        :ets.delete(tid, {db, source, :list, source_idx})

        dest_min_idx = find_min_index(tid, db, dest)
        :ets.insert(tid, {{db, dest, :list, dest_min_idx - 1}, popped_value})

        :ok
    end
  end

  # Private helpers

  @spec list_exists?(:ets.tid(), db(), key()) :: boolean()
  defp list_exists?(tid, db, key) do
    match_spec = [
      {{{db, key, :list, :_}, :_}, [], [true]}
    ]

    # Use select with limit 1 to check existence without counting all entries
    case :ets.select(tid, match_spec, 1) do
      {[_result | _], _continuation} -> true
      :"$end_of_table" -> false
    end
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

    # Use select with limit 1 to efficiently get just the first entry
    # Since ETS ordered_set maintains order, the first match is the minimum
    case :ets.select(tid, match_spec, 1) do
      {[entry | _], _continuation} -> entry
      :"$end_of_table" -> nil
    end
  end

  @spec find_max_index_entry(:ets.tid(), db(), key()) :: {integer(), any()} | nil
  defp find_max_index_entry(tid, db, key) do
    match_spec = [
      {{{db, key, :list, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}
    ]

    # Use select_reverse with limit 1 to efficiently get just the last entry
    # Since ETS ordered_set maintains order, the first match in reverse is the maximum
    case :ets.select_reverse(tid, match_spec, 1) do
      {[entry | _], _continuation} -> entry
      :"$end_of_table" -> nil
    end
  end

  @spec fetch_all_entries_sorted(:ets.tid(), db(), key()) :: [{integer(), any()}]
  defp fetch_all_entries_sorted(tid, db, key) do
    match_spec = [
      {{{db, key, :list, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}
    ]

    # ETS ordered_set already returns entries in key order, no need to sort
    :ets.select(tid, match_spec)
  end

  @spec normalize_index(integer(), non_neg_integer()) :: non_neg_integer()
  defp normalize_index(idx, len) when idx < 0 do
    max(0, len + idx)
  end

  defp normalize_index(idx, _len) do
    max(0, idx)
  end
end
