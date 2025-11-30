defmodule Veidrodelis.ListStore do
  @moduledoc """
  A GenServer that manages a map of lists indexed by arbitrary keys.

  Supports Redis-like list operations:
  - LPUSH/RPUSH - push elements to head/tail
  - LPUSHX/RPUSHX - push only if key exists
  - LPOP/RPOP - pop from head/tail
  - LREM - remove occurrences of element
  - LTRIM - trim list to range
  - LSET - set element at index
  - LINSERT - insert element before/after pivot
  - RPOPLPUSH - atomic pop from source and push to dest
  - DEL - delete a list

  Empty lists are automatically deleted.

  TODO

  Use pool and dispatch by db
  """

  use GenServer

  @type server :: GenServer.server()
  @type db :: non_neg_integer()
  @type key :: any()
  @type value :: any()
  @type position :: :before | :after

  # Client API

  @doc """
  Starts the list store server.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, opts)
  end

  @doc """
  Insert all values at the head of the list.
  Elements are inserted one after the other, so LPUSH key "a" "b" "c"
  results in ["c", "b", "a"] being prepended.
  """
  @spec lpush(server(), db(), key(), [value()]) :: :ok
  def lpush(server, db, key, values) when is_list(values) do
    GenServer.cast(server, {:lpush, db, key, values})
  end

  @doc """
  Insert all values at the tail of the list.
  Elements are inserted in order.
  """
  @spec rpush(server(), db(), key(), [value()]) :: :ok
  def rpush(server, db, key, values) when is_list(values) do
    GenServer.cast(server, {:rpush, db, key, values})
  end

  @doc """
  Insert values at the head, only if the key exists.
  """
  @spec lpushx(server(), db(), key(), [value()]) :: :ok
  def lpushx(server, db, key, values) when is_list(values) do
    GenServer.cast(server, {:lpushx, db, key, values})
  end

  @doc """
  Insert values at the tail, only if the key exists.
  """
  @spec rpushx(server(), db(), key(), [value()]) :: :ok
  def rpushx(server, db, key, values) when is_list(values) do
    GenServer.cast(server, {:rpushx, db, key, values})
  end

  @doc """
  Remove and return the first element of the list.
  """
  @spec lpop(server(), db(), key()) :: :ok
  def lpop(server, db, key) do
    GenServer.cast(server, {:lpop, db, key})
  end

  @doc """
  Remove and return the last element of the list.
  """
  @spec rpop(server(), db(), key()) :: :ok
  def rpop(server, db, key) do
    GenServer.cast(server, {:rpop, db, key})
  end

  @doc """
  Remove the first count occurrences of element from the list.
  - count > 0: Remove elements from head to tail
  - count < 0: Remove elements from tail to head
  - count = 0: Remove all occurrences
  """
  @spec lrem(server(), db(), key(), integer(), value()) :: :ok
  def lrem(server, db, key, count, element) do
    GenServer.cast(server, {:lrem, db, key, count, element})
  end

  @doc """
  Trim the list to the specified range.
  Both start and stop are inclusive and support negative indices.
  """
  @spec ltrim(server(), db(), key(), integer(), integer()) :: :ok
  def ltrim(server, db, key, start_idx, stop_idx) do
    GenServer.cast(server, {:ltrim, db, key, start_idx, stop_idx})
  end

  @doc """
  Set the list element at index to value.
  Supports negative indices.
  """
  @spec lset(server(), db(), key(), integer(), value()) :: :ok
  def lset(server, db, key, index, value) do
    GenServer.cast(server, {:lset, db, key, index, value})
  end

  @doc """
  Insert value before or after the pivot element.
  Position must be :before or :after.
  """
  @spec linsert(server(), db(), key(), position(), value(), value()) :: :ok
  def linsert(server, db, key, position, pivot, value) when position in [:before, :after] do
    GenServer.cast(server, {:linsert, db, key, position, pivot, value})
  end

  @doc """
  Atomically pop the last element from source and push it to the head of dest.
  """
  @spec rpoplpush(server(), db(), key(), key()) :: :ok
  def rpoplpush(server, db, source, dest) do
    GenServer.cast(server, {:rpoplpush, db, source, dest})
  end

  @doc """
  Delete the list at the specified key.
  """
  @spec del(server(), db(), key()) :: :ok
  def del(server, db, key) do
    GenServer.cast(server, {:del, db, key})
  end

  @doc """
  Get a range of elements from the list.
  Both start and stop are inclusive and support negative indices.
  """
  @spec get_range(server(), db(), key(), integer(), integer()) :: [value()]
  def get_range(server, db, key, start_idx, stop_idx) do
    GenServer.call(server, {:get_range, db, key, start_idx, stop_idx})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:lpush, db, key, values}, state) do
    db_key = {db, key}
    list = Map.get(state, db_key, [])
    # Insert elements one by one at head, so reverse first
    new_list = Enum.reverse(values) ++ list
    {:noreply, Map.put(state, db_key, new_list)}
  end

  def handle_cast({:rpush, db, key, values}, state) do
    db_key = {db, key}
    list = Map.get(state, db_key, [])
    new_list = list ++ values
    {:noreply, Map.put(state, db_key, new_list)}
  end

  def handle_cast({:lpushx, db, key, values}, state) do
    db_key = {db, key}
    case Map.get(state, db_key) do
      nil ->
        {:noreply, state}

      list ->
        new_list = Enum.reverse(values) ++ list
        {:noreply, Map.put(state, db_key, new_list)}
    end
  end

  def handle_cast({:rpushx, db, key, values}, state) do
    db_key = {db, key}
    case Map.get(state, db_key) do
      nil ->
        {:noreply, state}

      list ->
        new_list = list ++ values
        {:noreply, Map.put(state, db_key, new_list)}
    end
  end

  def handle_cast({:lpop, db, key}, state) do
    db_key = {db, key}
    case Map.get(state, db_key) do
      nil ->
        {:noreply, state}

      [] ->
        {:noreply, Map.delete(state, db_key)}

      [_head | tail] ->
        new_state = if tail == [], do: Map.delete(state, db_key), else: Map.put(state, db_key, tail)
        {:noreply, new_state}
    end
  end

  def handle_cast({:rpop, db, key}, state) do
    db_key = {db, key}
    case Map.get(state, db_key) do
      nil ->
        {:noreply, state}

      [] ->
        {:noreply, Map.delete(state, db_key)}

      list ->
        new_list = Enum.drop(list, -1)
        new_state = if new_list == [], do: Map.delete(state, db_key), else: Map.put(state, db_key, new_list)
        {:noreply, new_state}
    end
  end

  def handle_cast({:lrem, db, key, count, element}, state) do
    db_key = {db, key}
    case Map.get(state, db_key) do
      nil ->
        {:noreply, state}

      list ->
        new_list = remove_elements(list, count, element)
        new_state = if new_list == [], do: Map.delete(state, db_key), else: Map.put(state, db_key, new_list)
        {:noreply, new_state}
    end
  end

  def handle_cast({:ltrim, db, key, start_idx, stop_idx}, state) do
    db_key = {db, key}
    case Map.get(state, db_key) do
      nil ->
        {:noreply, state}

      list ->
        new_list = slice_list(list, start_idx, stop_idx)
        new_state = if new_list == [], do: Map.delete(state, db_key), else: Map.put(state, db_key, new_list)
        {:noreply, new_state}
    end
  end

  def handle_cast({:lset, db, key, index, value}, state) do
    db_key = {db, key}
    case Map.get(state, db_key) do
      nil ->
        {:noreply, state}

      list ->
        case set_at_index(list, index, value) do
          {:ok, new_list} -> {:noreply, Map.put(state, db_key, new_list)}
          :error -> {:noreply, state}
        end
    end
  end

  def handle_cast({:linsert, db, key, position, pivot, value}, state) do
    db_key = {db, key}
    case Map.get(state, db_key) do
      nil ->
        {:noreply, state}

      list ->
        case insert_at_pivot(list, position, pivot, value) do
          {:ok, new_list} -> {:noreply, Map.put(state, db_key, new_list)}
          :error -> {:noreply, state}
        end
    end
  end

  def handle_cast({:rpoplpush, db, source, dest}, state) do
    source_key = {db, source}
    dest_key = {db, dest}
    case Map.get(state, source_key) do
      nil ->
        {:noreply, state}

      [] ->
        {:noreply, Map.delete(state, source_key)}

      source_list ->
        popped = List.last(source_list)
        new_source = Enum.drop(source_list, -1)

        if source == dest do
          # Same key: just rotate the list
          new_list = [popped | new_source]
          {:noreply, Map.put(state, dest_key, new_list)}
        else
          # Different keys: update both
          dest_list = Map.get(state, dest_key, [])
          new_dest = [popped | dest_list]

          state =
            if new_source == [], do: Map.delete(state, source_key), else: Map.put(state, source_key, new_source)

          state = Map.put(state, dest_key, new_dest)
          {:noreply, state}
        end
    end
  end

  def handle_cast({:del, db, key}, state) do
    db_key = {db, key}
    {:noreply, Map.delete(state, db_key)}
  end

  @impl true
  def handle_call({:get_range, db, key, start_idx, stop_idx}, _from, state) do
    db_key = {db, key}
    list = Map.get(state, db_key, [])
    result = slice_list(list, start_idx, stop_idx)
    {:reply, result, state}
  end

  # Helper functions

  @spec remove_elements([value()], integer(), value()) :: [value()]
  defp remove_elements(list, count, element) when count > 0 do
    # Remove up to count occurrences from head to tail
    {_removed, result} =
      Enum.reduce(list, {0, []}, fn item, {removed, acc} ->
        if item == element and removed < count do
          {removed + 1, acc}
        else
          {removed, [item | acc]}
        end
      end)

    Enum.reverse(result)
  end

  defp remove_elements(list, count, element) when count < 0 do
    # Remove up to abs(count) occurrences from tail to head
    list
    |> Enum.reverse()
    |> remove_elements(abs(count), element)
    |> Enum.reverse()
  end

  defp remove_elements(list, 0, element) do
    # Remove all occurrences
    Enum.reject(list, fn x -> x == element end)
  end

  @spec slice_list([value()], integer(), integer()) :: [value()]
  defp slice_list(list, start_idx, stop_idx) do
    len = length(list)
    start_pos = normalize_index(start_idx, len)
    stop_pos = normalize_index(stop_idx, len)

    if start_pos > stop_pos or start_pos >= len do
      []
    else
      list
      |> Enum.slice(start_pos, stop_pos - start_pos + 1)
    end
  end

  @spec normalize_index(integer(), non_neg_integer()) :: non_neg_integer()
  defp normalize_index(idx, len) when idx < 0 do
    max(0, len + idx)
  end

  defp normalize_index(idx, _len) do
    max(0, idx)
  end

  @spec set_at_index([value()], integer(), value()) :: {:ok, [value()]} | :error
  defp set_at_index(list, index, value) do
    len = length(list)
    pos = if index < 0, do: len + index, else: index

    if pos >= 0 and pos < len do
      new_list = List.replace_at(list, pos, value)
      {:ok, new_list}
    else
      :error
    end
  end

  @spec insert_at_pivot([value()], position(), value(), value()) :: {:ok, [value()]} | :error
  defp insert_at_pivot(list, position, pivot, value) do
    case find_pivot_index(list, pivot) do
      nil ->
        :error

      index ->
        insert_pos = if position == :before, do: index, else: index + 1
        new_list = List.insert_at(list, insert_pos, value)
        {:ok, new_list}
    end
  end

  @spec find_pivot_index([value()], value()) :: non_neg_integer() | nil
  defp find_pivot_index(list, pivot) do
    Enum.find_index(list, fn x -> x == pivot end)
  end
end
