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
  """

  use GenServer

  @type server :: GenServer.server()
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
  @spec lpush(server(), key(), [value()]) :: :ok
  def lpush(server, key, values) when is_list(values) do
    GenServer.cast(server, {:lpush, key, values})
  end

  @doc """
  Insert all values at the tail of the list.
  Elements are inserted in order.
  """
  @spec rpush(server(), key(), [value()]) :: :ok
  def rpush(server, key, values) when is_list(values) do
    GenServer.cast(server, {:rpush, key, values})
  end

  @doc """
  Insert values at the head, only if the key exists.
  """
  @spec lpushx(server(), key(), [value()]) :: :ok
  def lpushx(server, key, values) when is_list(values) do
    GenServer.cast(server, {:lpushx, key, values})
  end

  @doc """
  Insert values at the tail, only if the key exists.
  """
  @spec rpushx(server(), key(), [value()]) :: :ok
  def rpushx(server, key, values) when is_list(values) do
    GenServer.cast(server, {:rpushx, key, values})
  end

  @doc """
  Remove and return the first element of the list.
  """
  @spec lpop(server(), key()) :: :ok
  def lpop(server, key) do
    GenServer.cast(server, {:lpop, key})
  end

  @doc """
  Remove and return the last element of the list.
  """
  @spec rpop(server(), key()) :: :ok
  def rpop(server, key) do
    GenServer.cast(server, {:rpop, key})
  end

  @doc """
  Remove the first count occurrences of element from the list.
  - count > 0: Remove elements from head to tail
  - count < 0: Remove elements from tail to head
  - count = 0: Remove all occurrences
  """
  @spec lrem(server(), key(), integer(), value()) :: :ok
  def lrem(server, key, count, element) do
    GenServer.cast(server, {:lrem, key, count, element})
  end

  @doc """
  Trim the list to the specified range.
  Both start and stop are inclusive and support negative indices.
  """
  @spec ltrim(server(), key(), integer(), integer()) :: :ok
  def ltrim(server, key, start_idx, stop_idx) do
    GenServer.cast(server, {:ltrim, key, start_idx, stop_idx})
  end

  @doc """
  Set the list element at index to value.
  Supports negative indices.
  """
  @spec lset(server(), key(), integer(), value()) :: :ok
  def lset(server, key, index, value) do
    GenServer.cast(server, {:lset, key, index, value})
  end

  @doc """
  Insert value before or after the pivot element.
  Position must be :before or :after.
  """
  @spec linsert(server(), key(), position(), value(), value()) :: :ok
  def linsert(server, key, position, pivot, value) when position in [:before, :after] do
    GenServer.cast(server, {:linsert, key, position, pivot, value})
  end

  @doc """
  Atomically pop the last element from source and push it to the head of dest.
  """
  @spec rpoplpush(server(), key(), key()) :: :ok
  def rpoplpush(server, source, dest) do
    GenServer.cast(server, {:rpoplpush, source, dest})
  end

  @doc """
  Delete the list at the specified key.
  """
  @spec del(server(), key()) :: :ok
  def del(server, key) do
    GenServer.cast(server, {:del, key})
  end

  @doc """
  Get a range of elements from the list.
  Both start and stop are inclusive and support negative indices.
  """
  @spec get_range(server(), key(), integer(), integer()) :: [value()]
  def get_range(server, key, start_idx, stop_idx) do
    GenServer.call(server, {:get_range, key, start_idx, stop_idx})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:lpush, key, values}, state) do
    list = Map.get(state, key, [])
    # Insert elements one by one at head, so reverse first
    new_list = Enum.reverse(values) ++ list
    {:noreply, Map.put(state, key, new_list)}
  end

  def handle_cast({:rpush, key, values}, state) do
    list = Map.get(state, key, [])
    new_list = list ++ values
    {:noreply, Map.put(state, key, new_list)}
  end

  def handle_cast({:lpushx, key, values}, state) do
    case Map.get(state, key) do
      nil ->
        {:noreply, state}

      list ->
        new_list = Enum.reverse(values) ++ list
        {:noreply, Map.put(state, key, new_list)}
    end
  end

  def handle_cast({:rpushx, key, values}, state) do
    case Map.get(state, key) do
      nil ->
        {:noreply, state}

      list ->
        new_list = list ++ values
        {:noreply, Map.put(state, key, new_list)}
    end
  end

  def handle_cast({:lpop, key}, state) do
    case Map.get(state, key) do
      nil ->
        {:noreply, state}

      [] ->
        {:noreply, Map.delete(state, key)}

      [_head | tail] ->
        new_state = if tail == [], do: Map.delete(state, key), else: Map.put(state, key, tail)
        {:noreply, new_state}
    end
  end

  def handle_cast({:rpop, key}, state) do
    case Map.get(state, key) do
      nil ->
        {:noreply, state}

      [] ->
        {:noreply, Map.delete(state, key)}

      list ->
        new_list = Enum.drop(list, -1)
        new_state = if new_list == [], do: Map.delete(state, key), else: Map.put(state, key, new_list)
        {:noreply, new_state}
    end
  end

  def handle_cast({:lrem, key, count, element}, state) do
    case Map.get(state, key) do
      nil ->
        {:noreply, state}

      list ->
        new_list = remove_elements(list, count, element)
        new_state = if new_list == [], do: Map.delete(state, key), else: Map.put(state, key, new_list)
        {:noreply, new_state}
    end
  end

  def handle_cast({:ltrim, key, start_idx, stop_idx}, state) do
    case Map.get(state, key) do
      nil ->
        {:noreply, state}

      list ->
        new_list = slice_list(list, start_idx, stop_idx)
        new_state = if new_list == [], do: Map.delete(state, key), else: Map.put(state, key, new_list)
        {:noreply, new_state}
    end
  end

  def handle_cast({:lset, key, index, value}, state) do
    case Map.get(state, key) do
      nil ->
        {:noreply, state}

      list ->
        case set_at_index(list, index, value) do
          {:ok, new_list} -> {:noreply, Map.put(state, key, new_list)}
          :error -> {:noreply, state}
        end
    end
  end

  def handle_cast({:linsert, key, position, pivot, value}, state) do
    case Map.get(state, key) do
      nil ->
        {:noreply, state}

      list ->
        case insert_at_pivot(list, position, pivot, value) do
          {:ok, new_list} -> {:noreply, Map.put(state, key, new_list)}
          :error -> {:noreply, state}
        end
    end
  end

  def handle_cast({:rpoplpush, source, dest}, state) do
    case Map.get(state, source) do
      nil ->
        {:noreply, state}

      [] ->
        {:noreply, Map.delete(state, source)}

      source_list ->
        popped = List.last(source_list)
        new_source = Enum.drop(source_list, -1)

        if source == dest do
          # Same key: just rotate the list
          new_list = [popped | new_source]
          {:noreply, Map.put(state, dest, new_list)}
        else
          # Different keys: update both
          dest_list = Map.get(state, dest, [])
          new_dest = [popped | dest_list]

          state =
            if new_source == [], do: Map.delete(state, source), else: Map.put(state, source, new_source)

          state = Map.put(state, dest, new_dest)
          {:noreply, state}
        end
    end
  end

  def handle_cast({:del, key}, state) do
    {:noreply, Map.delete(state, key)}
  end

  @impl true
  def handle_call({:get_range, key, start_idx, stop_idx}, _from, state) do
    list = Map.get(state, key, [])
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
