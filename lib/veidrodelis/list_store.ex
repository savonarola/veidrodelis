defmodule Vdr.ListStore do
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

  TODO use 2-list representation
  to make push-pop from both ends effective
  """

  use GenServer

  defstruct [:pid]

  @type t :: %__MODULE__{
          pid: pid()
        }

  @type db :: non_neg_integer()
  @type key :: any()
  @type value :: any()
  @type position :: :before | :after
  @type decode_fun :: (key(), binary() -> term())

  # Client API

  @doc """
  Creates a new list store.

  Options:
  - `:decode_fun` - A function `(key, binary) -> term()` used to decode binary values
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    decode_fun = Keyword.get(opts, :decode_fun, fn _key, val -> val end)
    {:ok, pid} = GenServer.start_link(__MODULE__, %{decode_fun: decode_fun}, opts)
    %__MODULE__{pid: pid}
  end

  @doc """
  Insert all values at the head of the list.
  Elements are inserted one after the other, so LPUSH key "a" "b" "c"
  results in ["c", "b", "a"] being prepended.
  """
  @spec lpush(t(), db(), key(), [value()]) :: :ok
  def lpush(%__MODULE__{pid: pid}, db, key, values) when is_list(values) do
    GenServer.cast(pid, {:lpush, db, key, values})
  end

  @doc """
  Insert all values at the tail of the list.
  Elements are inserted in order.
  """
  @spec rpush(t(), db(), key(), [value()]) :: :ok
  def rpush(%__MODULE__{pid: pid}, db, key, values) when is_list(values) do
    GenServer.cast(pid, {:rpush, db, key, values})
  end

  @doc """
  Insert values at the head, only if the key exists.
  """
  @spec lpushx(t(), db(), key(), [value()]) :: :ok
  def lpushx(%__MODULE__{pid: pid}, db, key, values) when is_list(values) do
    GenServer.cast(pid, {:lpushx, db, key, values})
  end

  @doc """
  Insert values at the tail, only if the key exists.
  """
  @spec rpushx(t(), db(), key(), [value()]) :: :ok
  def rpushx(%__MODULE__{pid: pid}, db, key, values) when is_list(values) do
    GenServer.cast(pid, {:rpushx, db, key, values})
  end

  @doc """
  Remove and return the first element of the list.
  """
  @spec lpop(t(), db(), key()) :: :ok
  def lpop(%__MODULE__{pid: pid}, db, key) do
    GenServer.cast(pid, {:lpop, db, key})
  end

  @doc """
  Remove and return the last element of the list.
  """
  @spec rpop(t(), db(), key()) :: :ok
  def rpop(%__MODULE__{pid: pid}, db, key) do
    GenServer.cast(pid, {:rpop, db, key})
  end

  @doc """
  Remove the first count occurrences of element from the list.
  - count > 0: Remove elements from head to tail
  - count < 0: Remove elements from tail to head
  - count = 0: Remove all occurrences
  """
  @spec lrem(t(), db(), key(), integer(), value()) :: :ok
  def lrem(%__MODULE__{pid: pid}, db, key, count, element) do
    GenServer.cast(pid, {:lrem, db, key, count, element})
  end

  @doc """
  Trim the list to the specified range.
  Both start and stop are inclusive and support negative indices.
  """
  @spec ltrim(t(), db(), key(), integer(), integer()) :: :ok
  def ltrim(%__MODULE__{pid: pid}, db, key, start_idx, stop_idx) do
    GenServer.cast(pid, {:ltrim, db, key, start_idx, stop_idx})
  end

  @doc """
  Set the list element at index to value.
  Supports negative indices.
  """
  @spec lset(t(), db(), key(), integer(), value()) :: :ok
  def lset(%__MODULE__{pid: pid}, db, key, index, value) do
    GenServer.cast(pid, {:lset, db, key, index, value})
  end

  @doc """
  Insert value before or after the pivot element.
  Position must be :before or :after.
  """
  @spec linsert(t(), db(), key(), position(), value(), value()) :: :ok
  def linsert(%__MODULE__{pid: pid}, db, key, position, pivot, value)
      when position in [:before, :after] do
    GenServer.cast(pid, {:linsert, db, key, position, pivot, value})
  end

  @doc """
  Atomically pop the last element from source and push it to the head of dest.
  """
  @spec rpoplpush(t(), db(), key(), key()) :: :ok
  def rpoplpush(%__MODULE__{pid: pid}, db, source, dest) do
    GenServer.cast(pid, {:rpoplpush, db, source, dest})
  end

  @doc """
  Delete the list at the specified key.
  """
  @spec del(t(), db(), key()) :: :ok
  def del(%__MODULE__{pid: pid}, db, key) do
    GenServer.cast(pid, {:del, db, key})
  end

  @doc """
  Get a range of elements from the list.
  Both start and stop are inclusive and support negative indices.
  """
  @spec get_range(t(), db(), key(), integer(), integer()) :: [value()]
  def get_range(%__MODULE__{pid: pid}, db, key, start_idx, stop_idx) do
    GenServer.call(pid, {:get_range, db, key, start_idx, stop_idx})
  end

  @doc """
  Stops the GenServer and releases resources.
  """
  @spec destroy(t()) :: :ok
  def destroy(%__MODULE__{pid: pid}) do
    GenServer.stop(pid)
    :ok
  end

  # Server callbacks

  @impl true
  def init(opts) do
    decode_fun = Map.get(opts, :decode_fun, fn _key, val -> val end)
    {:ok, %{data: %{}, decode_fun: decode_fun}}
  end

  @impl true
  def handle_cast({:lpush, db, key, values}, state) do
    db_key = {db, key}
    decode_fun = state.decode_fun
    list = Map.get(state.data, db_key, [])
    # Decode binary values and insert elements one by one at head, so reverse first
    decoded_values = Enum.map(values, &decode_if_binary(decode_fun, key, &1))
    new_list = Enum.reverse(decoded_values) ++ list
    {:noreply, %{state | data: Map.put(state.data, db_key, new_list)}}
  end

  def handle_cast({:rpush, db, key, values}, state) do
    db_key = {db, key}
    decode_fun = state.decode_fun
    list = Map.get(state.data, db_key, [])
    decoded_values = Enum.map(values, &decode_if_binary(decode_fun, key, &1))
    new_list = list ++ decoded_values
    {:noreply, %{state | data: Map.put(state.data, db_key, new_list)}}
  end

  def handle_cast({:lpushx, db, key, values}, state) do
    db_key = {db, key}
    decode_fun = state.decode_fun

    case Map.get(state.data, db_key) do
      nil ->
        {:noreply, state}

      list ->
        decoded_values = Enum.map(values, &decode_if_binary(decode_fun, key, &1))
        new_list = Enum.reverse(decoded_values) ++ list
        {:noreply, %{state | data: Map.put(state.data, db_key, new_list)}}
    end
  end

  def handle_cast({:rpushx, db, key, values}, state) do
    db_key = {db, key}
    decode_fun = state.decode_fun

    case Map.get(state.data, db_key) do
      nil ->
        {:noreply, state}

      list ->
        decoded_values = Enum.map(values, &decode_if_binary(decode_fun, key, &1))
        new_list = list ++ decoded_values
        {:noreply, %{state | data: Map.put(state.data, db_key, new_list)}}
    end
  end

  def handle_cast({:lpop, db, key}, state) do
    db_key = {db, key}

    case Map.get(state.data, db_key) do
      nil ->
        {:noreply, state}

      [] ->
        {:noreply, %{state | data: Map.delete(state.data, db_key)}}

      [_head | tail] ->
        new_data =
          if tail == [],
            do: Map.delete(state.data, db_key),
            else: Map.put(state.data, db_key, tail)

        {:noreply, %{state | data: new_data}}
    end
  end

  def handle_cast({:rpop, db, key}, state) do
    db_key = {db, key}

    case Map.get(state.data, db_key) do
      nil ->
        {:noreply, state}

      [] ->
        {:noreply, %{state | data: Map.delete(state.data, db_key)}}

      list ->
        new_list = Enum.drop(list, -1)

        new_data =
          if new_list == [],
            do: Map.delete(state.data, db_key),
            else: Map.put(state.data, db_key, new_list)

        {:noreply, %{state | data: new_data}}
    end
  end

  def handle_cast({:lrem, db, key, count, element}, state) do
    db_key = {db, key}
    decode_fun = state.decode_fun

    case Map.get(state.data, db_key) do
      nil ->
        {:noreply, state}

      list ->
        decoded_element = decode_if_binary(decode_fun, key, element)
        new_list = remove_elements(list, count, decoded_element)

        new_data =
          if new_list == [],
            do: Map.delete(state.data, db_key),
            else: Map.put(state.data, db_key, new_list)

        {:noreply, %{state | data: new_data}}
    end
  end

  def handle_cast({:ltrim, db, key, start_idx, stop_idx}, state) do
    db_key = {db, key}

    case Map.get(state.data, db_key) do
      nil ->
        {:noreply, state}

      list ->
        new_list = slice_list(list, start_idx, stop_idx)

        new_data =
          if new_list == [],
            do: Map.delete(state.data, db_key),
            else: Map.put(state.data, db_key, new_list)

        {:noreply, %{state | data: new_data}}
    end
  end

  def handle_cast({:lset, db, key, index, value}, state) do
    db_key = {db, key}
    decode_fun = state.decode_fun

    case Map.get(state.data, db_key) do
      nil ->
        {:noreply, state}

      list ->
        decoded_value = decode_if_binary(decode_fun, key, value)

        case set_at_index(list, index, decoded_value) do
          {:ok, new_list} -> {:noreply, %{state | data: Map.put(state.data, db_key, new_list)}}
          :error -> {:noreply, state}
        end
    end
  end

  def handle_cast({:linsert, db, key, position, pivot, value}, state) do
    db_key = {db, key}
    decode_fun = state.decode_fun

    case Map.get(state.data, db_key) do
      nil ->
        {:noreply, state}

      list ->
        decoded_pivot = decode_if_binary(decode_fun, key, pivot)
        decoded_value = decode_if_binary(decode_fun, key, value)

        case insert_at_pivot(list, position, decoded_pivot, decoded_value) do
          {:ok, new_list} -> {:noreply, %{state | data: Map.put(state.data, db_key, new_list)}}
          :error -> {:noreply, state}
        end
    end
  end

  def handle_cast({:rpoplpush, db, source, dest}, state) do
    source_key = {db, source}
    dest_key = {db, dest}

    case Map.get(state.data, source_key) do
      nil ->
        {:noreply, state}

      [] ->
        {:noreply, %{state | data: Map.delete(state.data, source_key)}}

      source_list ->
        popped = List.last(source_list)
        new_source = Enum.drop(source_list, -1)

        if source == dest do
          # Same key: just rotate the list
          new_list = [popped | new_source]
          {:noreply, %{state | data: Map.put(state.data, dest_key, new_list)}}
        else
          # Different keys: update both
          dest_list = Map.get(state.data, dest_key, [])
          new_dest = [popped | dest_list]

          new_data =
            if new_source == [],
              do: Map.delete(state.data, source_key),
              else: Map.put(state.data, source_key, new_source)

          new_data = Map.put(new_data, dest_key, new_dest)
          {:noreply, %{state | data: new_data}}
        end
    end
  end

  def handle_cast({:del, db, key}, state) do
    db_key = {db, key}
    {:noreply, %{state | data: Map.delete(state.data, db_key)}}
  end

  @impl true
  def handle_call({:get_range, db, key, start_idx, stop_idx}, _from, state) do
    db_key = {db, key}
    list = Map.get(state.data, db_key, [])
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

  # Helper function to decode binary values using the decode function
  @spec decode_if_binary(decode_fun(), key(), value()) :: term()
  defp decode_if_binary(decode_fun, key, value) when is_binary(value) do
    decode_fun.(key, value)
  end

  defp decode_if_binary(_decode_fun, _key, value) do
    value
  end
end
