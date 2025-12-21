defmodule Vdr.MapProj.Lists do
  @moduledoc """
  List store operations for MapProj.

  Stores list values in a map structure using raw binaries.
  Each list is stored as a plain Elixir list of binary elements.
  """

  @type db :: non_neg_integer()
  @type key :: binary()
  @type element :: binary()
  @type store :: %{db() => %{key() => list()}}
  @type position :: :before | :after

  @doc """
  Insert all values at the head of the list (left side).
  Returns the updated store.
  """
  @spec lpush(store(), db(), key(), [element()]) :: store()
  def lpush(store, db, key, values) when is_list(values) do
    db_map = Map.get(store, db, %{})
    list = get_entries(db_map, key)

    new_entries = Enum.reverse(values) ++ list

    store_entries(store, db, key, new_entries)
  end

  @doc """
  Insert all values at the tail of the list (right side).
  Returns the updated store.
  """
  @spec rpush(store(), db(), key(), [element()]) :: store()
  def rpush(store, db, key, values) when is_list(values) do
    db_map = Map.get(store, db, %{})
    list = get_entries(db_map, key)

    new_entries = list ++ values

    store_entries(store, db, key, new_entries)
  end

  @doc """
  Insert values at the head, only if the key exists.
  Returns the updated store.
  """
  @spec lpushx(store(), db(), key(), [element()]) :: store()
  def lpushx(store, db, key, values) when is_list(values) do
    db_map = Map.get(store, db, %{})

    if Map.has_key?(db_map, key) do
      lpush(store, db, key, values)
    else
      store
    end
  end

  @doc """
  Insert values at the tail, only if the key exists.
  Returns the updated store.
  """
  @spec rpushx(store(), db(), key(), [element()]) :: store()
  def rpushx(store, db, key, values) when is_list(values) do
    db_map = Map.get(store, db, %{})

    if Map.has_key?(db_map, key) do
      rpush(store, db, key, values)
    else
      store
    end
  end

  @doc """
  Remove and return the first element of the list (from the head).
  Returns the updated store.
  """
  @spec lpop(store(), db(), key()) :: store()
  def lpop(store, db, key) do
    db_map = Map.get(store, db, %{})

    case get_entries(db_map, key) do
      [] ->
        store

      [_head | tail] ->
        store_entries(store, db, key, tail)
    end
  end

  @doc """
  Remove and return the last element of the list (from the tail).
  Returns the updated store.
  """
  @spec rpop(store(), db(), key()) :: store()
  def rpop(store, db, key) do
    db_map = Map.get(store, db, %{})
    list = get_entries(db_map, key)

    case Enum.split(list, -1) do
      {[], []} ->
        store

      {init, [_last]} ->
        store_entries(store, db, key, init)
    end
  end

  @doc """
  Remove the first count occurrences of element from the list.
  Returns the updated store.
  """
  @spec lrem(store(), db(), key(), integer(), element()) :: store()
  def lrem(store, db, key, count, element) do
    db_map = Map.get(store, db, %{})
    list = get_entries(db_map, key)

    new_list =
      cond do
        count > 0 ->
          remove_n_from_head(list, element, count)

        count < 0 ->
          list
          |> Enum.reverse()
          |> remove_n_from_head(element, abs(count))
          |> Enum.reverse()

        count == 0 ->
          Enum.reject(list, fn elem -> elem == element end)
      end

    store_entries(store, db, key, new_list)
  end

  @doc """
  Trim the list to the specified range.
  Returns the updated store.
  """
  @spec ltrim(store(), db(), key(), integer(), integer()) :: store()
  def ltrim(store, db, key, start_idx, stop_idx) do
    db_map = Map.get(store, db, %{})
    list = get_entries(db_map, key)
    len = length(list)

    start_pos = normalize_index(start_idx, len)
    stop_pos = normalize_index(stop_idx, len)

    new_list =
      if start_pos > stop_pos or start_pos >= len do
        []
      else
        Enum.slice(list, start_pos..min(stop_pos, len - 1))
      end

    store_entries(store, db, key, new_list)
  end

  @doc """
  Set the list element at index to value.
  Returns the updated store.
  """
  @spec lset(store(), db(), key(), integer(), element()) :: store()
  def lset(store, db, key, index, value) do
    db_map = Map.get(store, db, %{})
    list = get_entries(db_map, key)
    len = length(list)

    pos = if index < 0, do: len + index, else: index

    if pos >= 0 and pos < len do
      new_list = Elixir.List.replace_at(list, pos, value)
      store_entries(store, db, key, new_list)
    else
      store
    end
  end

  @doc """
  Insert value before or after the pivot element.
  Returns the updated store.
  """
  @spec linsert(store(), db(), key(), position(), element(), element()) :: store()
  def linsert(store, db, key, position, pivot, value)
      when position in [:before, :after] do
    db_map = Map.get(store, db, %{})
    list = get_entries(db_map, key)

    case Enum.find_index(list, fn elem -> elem == pivot end) do
      nil ->
        store

      pivot_idx ->
        insert_idx = if position == :before, do: pivot_idx, else: pivot_idx + 1
        new_list = Elixir.List.insert_at(list, insert_idx, value)
        store_entries(store, db, key, new_list)
    end
  end

  @doc """
  Atomically pop the last element from source and push it to the head of dest.
  Returns the updated store.
  """
  @spec rpoplpush(store(), db(), key(), key()) :: store()
  def rpoplpush(store, db, source, dest) do
    db_map = Map.get(store, db, %{})
    source_list = get_entries(db_map, source)

    case Enum.split(source_list, -1) do
      {[], []} ->
        store

      {source_init, [popped]} ->
        if source == dest do
          # Same list - rotate: move last element to front
          store_entries(store, db, source, [popped | source_init])
        else
          # Different lists
          dest_list = get_entries(db_map, dest)
          store = store_entries(store, db, source, source_init)
          store_entries(store, db, dest, [popped | dest_list])
        end
    end
  end

  @doc """
  Get a range of elements from the list.
  Both start and stop are inclusive and support negative indices.
  Returns binary values.
  """
  @spec lrange(store(), db(), key(), integer(), integer()) :: [binary()]
  def lrange(store, db, key, start_idx, stop_idx) do
    db_map = Map.get(store, db, %{})
    list = get_entries(db_map, key)
    len = length(list)

    start_pos = normalize_index(start_idx, len)
    stop_pos = normalize_index(stop_idx, len)

    if start_pos > stop_pos or start_pos >= len do
      []
    else
      Enum.slice(list, start_pos..min(stop_pos, len - 1))
    end
  end

  @doc """
  Returns the length of the list.
  """
  @spec llen(store(), db(), key()) :: non_neg_integer()
  def llen(store, db, key) do
    db_map = Map.get(store, db, %{})
    list = get_entries(db_map, key)
    length(list)
  end

  # Private helpers

  @spec get_entries(%{key() => list()}, key()) :: [binary()]
  defp get_entries(db_map, key) do
    case Map.get(db_map, key) do
      nil -> []
      list when is_list(list) -> list
      _ -> []
    end
  end

  @spec store_entries(store(), db(), key(), [binary()]) :: store()
  defp store_entries(store, db, key, []) do
    # Remove the key when the list is empty
    case Map.get(store, db) do
      nil ->
        store

      db_map ->
        new_db_map = Map.delete(db_map, key)
        Map.put(store, db, new_db_map)
    end
  end

  defp store_entries(store, db, key, entries) when is_list(entries) do
    db_map = Map.get(store, db, %{})
    new_db_map = Map.put(db_map, key, entries)
    Map.put(store, db, new_db_map)
  end

  @spec remove_n_from_head([binary()], binary(), non_neg_integer()) :: [binary()]
  defp remove_n_from_head(list, _element, 0), do: list
  defp remove_n_from_head([], _element, _count), do: []

  defp remove_n_from_head([head | tail], element, count) do
    if head == element do
      remove_n_from_head(tail, element, count - 1)
    else
      [head | remove_n_from_head(tail, element, count)]
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
