defmodule Vdr.TS.Watch do
  @moduledoc """
  Watch storage for tracking key-based subscriptions.

  Allows multiple processes to register watches for specific keys,
  associating each watch with a reference value. Supports efficient
  lookup and deletion operations.

  ## Internal Structure

  The watch storage uses two collections:
  1. `key_to_pids`: `%{key => %{pid => ref}}` - maps keys to pid-to-ref mappings
  2. `pid_to_keys`: `%{pid => MapSet.t()}` - maps pids to sets of keys

  ## Example

      watch = Vdr.TS.Watch.create()

      # Add watches
      {:ok, watch} = Vdr.TS.Watch.add(watch, self(), "user:123", :my_ref)
      {:ok, watch} = Vdr.TS.Watch.add(watch, self(), "user:456", :another_ref)

      # Lookup
      [{:my_ref, _pid}] = Vdr.TS.Watch.lookup(watch, "user:123")

      # Delete single watch
      {:ok, watch} = Vdr.TS.Watch.delete(watch, self(), "user:123")

      # Delete all watches for a pid
      watch = Vdr.TS.Watch.delete_all(watch, self())
  """

  @type t :: %__MODULE__{
          key_to_pids: %{String.t() => %{pid() => term()}},
          pid_to_keys: %{pid() => MapSet.t(String.t())}
        }

  defstruct key_to_pids: %{},
            pid_to_keys: %{}

  @doc """
  Creates a new empty watch storage.

  ## Examples

      iex> watch = Vdr.TS.Watch.create()
      iex> is_struct(watch, Vdr.TS.Watch)
      true
  """
  @spec create() :: t()
  def create do
    %__MODULE__{}
  end

  @doc """
  Adds a watch entry for the given pid, key, and ref.

  Returns `{:ok, updated_watch}` on success, or `{:error, reason}` if the key
  is already registered for this pid.

  ## Parameters

    * `watch` - The watch storage
    * `pid` - The process identifier
    * `key` - The key to watch (string)
    * `ref` - The reference value to associate with this watch

  ## Examples

      iex> watch = Vdr.TS.Watch.create()
      iex> {:ok, watch} = Vdr.TS.Watch.add(watch, self(), "key1", :ref1)
      iex> {:error, :already_registered} = Vdr.TS.Watch.add(watch, self(), "key1", :ref2)
  """
  @spec add(t(), pid(), String.t(), term()) :: {:ok, t()} | {:error, atom()}
  def add(%__MODULE__{} = watch, pid, key, ref) when is_binary(key) do
    # Check if key already exists for this pid
    if get_in(watch.key_to_pids, [key, pid]) do
      {:error, :already_registered}
    else
      # Add to key_to_pids
      key_to_pids =
        Map.update(watch.key_to_pids, key, %{pid => ref}, fn pid_map ->
          Map.put(pid_map, pid, ref)
        end)

      # Add to pid_to_keys
      pid_to_keys =
        Map.update(watch.pid_to_keys, pid, MapSet.new([key]), fn keys ->
          MapSet.put(keys, key)
        end)

      {:ok, %{watch | key_to_pids: key_to_pids, pid_to_keys: pid_to_keys}}
    end
  end

  @doc """
  Deletes a single watch entry for the given pid and key.

  Returns `{:ok, updated_watch}` on success, or `{:error, reason}` if the
  watch entry does not exist.

  ## Parameters

    * `watch` - The watch storage
    * `pid` - The process identifier
    * `key` - The key to unwatch

  ## Examples

      iex> watch = Vdr.TS.Watch.create()
      iex> {:ok, watch} = Vdr.TS.Watch.add(watch, self(), "key1", :ref1)
      iex> {:ok, watch} = Vdr.TS.Watch.delete(watch, self(), "key1")
      iex> {:error, :not_found} = Vdr.TS.Watch.delete(watch, self(), "key1")
  """
  @spec delete(t(), pid(), String.t()) :: {:ok, t()} | {:error, atom()}
  def delete(%__MODULE__{} = watch, pid, key) when is_binary(key) do
    # Check if key exists for this pid
    unless get_in(watch.key_to_pids, [key, pid]) do
      {:error, :not_found}
    else
      # Remove from key_to_pids
      key_to_pids =
        Map.update(watch.key_to_pids, key, %{}, fn pid_map ->
          new_pid_map = Map.delete(pid_map, pid)

          # Clean up empty key entries
          if map_size(new_pid_map) == 0 do
            :delete_key
          else
            new_pid_map
          end
        end)

      key_to_pids =
        if Map.get(key_to_pids, key) == :delete_key do
          Map.delete(key_to_pids, key)
        else
          key_to_pids
        end

      # Remove from pid_to_keys
      pid_to_keys =
        Map.update(watch.pid_to_keys, pid, MapSet.new(), fn keys ->
          new_keys = MapSet.delete(keys, key)

          # Clean up empty pid entries
          if MapSet.size(new_keys) == 0 do
            :delete_pid
          else
            new_keys
          end
        end)

      pid_to_keys =
        if Map.get(pid_to_keys, pid) == :delete_pid do
          Map.delete(pid_to_keys, pid)
        else
          pid_to_keys
        end

      {:ok, %{watch | key_to_pids: key_to_pids, pid_to_keys: pid_to_keys}}
    end
  end

  @doc """
  Deletes all watch entries for the given pid.

  Returns the updated watch storage. This operation always succeeds,
  even if the pid has no watches.

  ## Parameters

    * `watch` - The watch storage
    * `pid` - The process identifier

  ## Examples

      iex> watch = Vdr.TS.Watch.create()
      iex> {:ok, watch} = Vdr.TS.Watch.add(watch, self(), "key1", :ref1)
      iex> {:ok, watch} = Vdr.TS.Watch.add(watch, self(), "key2", :ref2)
      iex> watch = Vdr.TS.Watch.delete_all(watch, self())
      iex> [] = Vdr.TS.Watch.lookup(watch, "key1")
  """
  @spec delete_all(t(), pid()) :: t()
  def delete_all(%__MODULE__{} = watch, pid) do
    # Get all keys for this pid
    keys = Map.get(watch.pid_to_keys, pid, MapSet.new())

    # Remove this pid from all keys in key_to_pids
    key_to_pids =
      Enum.reduce(keys, watch.key_to_pids, fn key, acc ->
        Map.update(acc, key, %{}, fn pid_map ->
          new_pid_map = Map.delete(pid_map, pid)

          # Mark for deletion if empty
          if map_size(new_pid_map) == 0 do
            :delete_key
          else
            new_pid_map
          end
        end)
      end)

    # Clean up empty key entries
    key_to_pids =
      Enum.reduce(keys, key_to_pids, fn key, acc ->
        if Map.get(acc, key) == :delete_key do
          Map.delete(acc, key)
        else
          acc
        end
      end)

    # Remove pid from pid_to_keys
    pid_to_keys = Map.delete(watch.pid_to_keys, pid)

    %{watch | key_to_pids: key_to_pids, pid_to_keys: pid_to_keys}
  end

  @doc """
  Looks up all watches for the given key.

  Returns a list of `{ref, pid}` tuples for all processes watching the key.

  ## Parameters

    * `watch` - The watch storage
    * `key` - The key to lookup

  ## Examples

      iex> watch = Vdr.TS.Watch.create()
      iex> {:ok, watch} = Vdr.TS.Watch.add(watch, self(), "key1", :ref1)
      iex> [{:ref1, _pid}] = Vdr.TS.Watch.lookup(watch, "key1")
      iex> [] = Vdr.TS.Watch.lookup(watch, "nonexistent")
  """
  @spec lookup(t(), String.t()) :: [{term(), pid()}]
  def lookup(%__MODULE__{} = watch, key) when is_binary(key) do
    case Map.get(watch.key_to_pids, key) do
      nil ->
        []

      pid_map ->
        Enum.map(pid_map, fn {pid, ref} -> {ref, pid} end)
    end
  end
end
