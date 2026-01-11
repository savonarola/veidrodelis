defmodule Vdr.TS.Watch do
  @moduledoc """
  Watch storage for tracking key-based subscriptions with database scoping.

  Allows multiple processes to register watches for specific keys in specific databases,
  associating each watch with a reference value. Supports efficient
  lookup and deletion operations.

  ## Internal Structure

  The watch storage uses two collections:
  1. `key_to_pids`: `%{{db, key} => %{pid => ref}}` - maps database-scoped keys to pid-to-ref mappings
  2. `pid_to_keys`: `%{pid => MapSet.t({db, key})}` - maps pids to sets of database-scoped keys

  ## Example

      watch = Vdr.TS.Watch.create()

      # Add watches (with database parameter)
      {:ok, watch} = Vdr.TS.Watch.add(watch, self(), 0, "user:123", :my_ref)
      {:ok, watch} = Vdr.TS.Watch.add(watch, self(), 0, "user:456", :another_ref)

      # Lookup
      [{:my_ref, _pid}] = Vdr.TS.Watch.lookup(watch, 0, "user:123")

      # Delete single watch
      {:ok, watch, _remaining} = Vdr.TS.Watch.delete(watch, self(), 0, "user:123")

      # Delete all watches for a pid
      watch = Vdr.TS.Watch.delete_all(watch, self())
  """

  @type db_key :: {non_neg_integer(), String.t()}

  @type t :: %__MODULE__{
          key_to_pids: %{db_key() => %{pid() => term()}},
          pid_to_keys: %{pid() => MapSet.t(db_key())}
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
  Adds a watch entry for the given pid, database, key, and ref.

  Returns `{:ok, updated_watch}` on success, or `{:error, reason}` if the key
  is already registered for this pid in this database.

  ## Parameters

    * `watch` - The watch storage
    * `pid` - The process identifier
    * `db` - The database number
    * `key` - The key to watch (string)
    * `ref` - The reference value to associate with this watch

  ## Examples

      iex> watch = Vdr.TS.Watch.create()
      iex> {:ok, watch} = Vdr.TS.Watch.add(watch, self(), 0, "key1", :ref1)
      iex> {:error, :already_registered} = Vdr.TS.Watch.add(watch, self(), 0, "key1", :ref2)
  """
  @spec add(t(), pid(), non_neg_integer(), String.t(), term()) :: {:ok, t()} | {:error, atom()}
  def add(%__MODULE__{} = watch, pid, db, key, ref) when is_integer(db) and is_binary(key) do
    db_key = {db, key}

    # Check if key already exists for this pid
    if get_in(watch.key_to_pids, [db_key, pid]) do
      {:error, :already_registered}
    else
      # Add to key_to_pids
      key_to_pids =
        Map.update(watch.key_to_pids, db_key, %{pid => ref}, fn pid_map ->
          Map.put(pid_map, pid, ref)
        end)

      # Add to pid_to_keys
      pid_to_keys =
        Map.update(watch.pid_to_keys, pid, MapSet.new([db_key]), fn keys ->
          MapSet.put(keys, db_key)
        end)

      {:ok, %{watch | key_to_pids: key_to_pids, pid_to_keys: pid_to_keys}}
    end
  end

  @doc """
  Deletes a single watch entry for the given pid, database, and key.

  Returns `{:ok, updated_watch, remaining_count}` on success, where `remaining_count`
  is the number of watches remaining for the pid. Returns `{:error, reason}` if the
  watch entry does not exist.

  ## Parameters

    * `watch` - The watch storage
    * `pid` - The process identifier
    * `db` - The database number
    * `key` - The key to unwatch

  ## Examples

      iex> watch = Vdr.TS.Watch.create()
      iex> {:ok, watch} = Vdr.TS.Watch.add(watch, self(), 0, "key1", :ref1)
      iex> {:ok, watch, 0} = Vdr.TS.Watch.delete(watch, self(), 0, "key1")
      iex> {:error, :not_found} = Vdr.TS.Watch.delete(watch, self(), 0, "key1")
  """
  @spec delete(t(), pid(), non_neg_integer(), String.t()) ::
          {:ok, t(), non_neg_integer()} | {:error, atom()}
  def delete(%__MODULE__{} = watch, pid, db, key) when is_integer(db) and is_binary(key) do
    db_key = {db, key}

    # Check if key exists for this pid
    unless get_in(watch.key_to_pids, [db_key, pid]) do
      {:error, :not_found}
    else
      # Remove from key_to_pids
      key_to_pids =
        Map.update(watch.key_to_pids, db_key, %{}, fn pid_map ->
          new_pid_map = Map.delete(pid_map, pid)

          # Clean up empty key entries
          if map_size(new_pid_map) == 0 do
            :delete_key
          else
            new_pid_map
          end
        end)

      key_to_pids =
        if Map.get(key_to_pids, db_key) == :delete_key do
          Map.delete(key_to_pids, db_key)
        else
          key_to_pids
        end

      # Remove from pid_to_keys
      pid_to_keys =
        Map.update(watch.pid_to_keys, pid, MapSet.new(), fn keys ->
          new_keys = MapSet.delete(keys, db_key)

          # Clean up empty pid entries
          if MapSet.size(new_keys) == 0 do
            :delete_pid
          else
            new_keys
          end
        end)

      remaining_count =
        case Map.get(pid_to_keys, pid) do
          :delete_pid -> 0
          keys when is_struct(keys, MapSet) -> MapSet.size(keys)
        end

      pid_to_keys =
        if Map.get(pid_to_keys, pid) == :delete_pid do
          Map.delete(pid_to_keys, pid)
        else
          pid_to_keys
        end

      {:ok, %{watch | key_to_pids: key_to_pids, pid_to_keys: pid_to_keys}, remaining_count}
    end
  end

  @doc """
  Deletes all watch entries for the given pid.

  Returns the updated watch storage. This operation always succeeds,
  even if the pid has no watches. Deletes watches across all databases.

  ## Parameters

    * `watch` - The watch storage
    * `pid` - The process identifier

  ## Examples

      iex> watch = Vdr.TS.Watch.create()
      iex> {:ok, watch} = Vdr.TS.Watch.add(watch, self(), 0, "key1", :ref1)
      iex> {:ok, watch} = Vdr.TS.Watch.add(watch, self(), 1, "key2", :ref2)
      iex> watch = Vdr.TS.Watch.delete_all(watch, self())
      iex> [] = Vdr.TS.Watch.lookup(watch, 0, "key1")
  """
  @spec delete_all(t(), pid()) :: t()
  def delete_all(%__MODULE__{} = watch, pid) do
    # Get all db_keys for this pid
    db_keys = Map.get(watch.pid_to_keys, pid, MapSet.new())

    # Remove this pid from all db_keys in key_to_pids
    key_to_pids =
      Enum.reduce(db_keys, watch.key_to_pids, fn db_key, acc ->
        Map.update(acc, db_key, %{}, fn pid_map ->
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
      Enum.reduce(db_keys, key_to_pids, fn db_key, acc ->
        if Map.get(acc, db_key) == :delete_key do
          Map.delete(acc, db_key)
        else
          acc
        end
      end)

    # Remove pid from pid_to_keys
    pid_to_keys = Map.delete(watch.pid_to_keys, pid)

    %{watch | key_to_pids: key_to_pids, pid_to_keys: pid_to_keys}
  end

  @doc """
  Looks up all watches for the given database and key.

  Returns a list of `{ref, pid}` tuples for all processes watching the key
  in the specified database.

  ## Parameters

    * `watch` - The watch storage
    * `db` - The database number
    * `key` - The key to lookup

  ## Examples

      iex> watch = Vdr.TS.Watch.create()
      iex> {:ok, watch} = Vdr.TS.Watch.add(watch, self(), 0, "key1", :ref1)
      iex> [{:ref1, _pid}] = Vdr.TS.Watch.lookup(watch, 0, "key1")
      iex> [] = Vdr.TS.Watch.lookup(watch, 0, "nonexistent")
  """
  @spec lookup(t(), non_neg_integer(), String.t()) :: [{term(), pid()}]
  def lookup(%__MODULE__{} = watch, db, key) when is_integer(db) and is_binary(key) do
    db_key = {db, key}

    case Map.get(watch.key_to_pids, db_key) do
      nil ->
        []

      pid_map ->
        Enum.map(pid_map, fn {pid, ref} -> {ref, pid} end)
    end
  end

  @doc """
  Returns all unique `{pid, ref}` pairs across all watches.

  This is useful for broadcasting messages to all watchers, such as
  sending Init messages when streaming mode starts.

  ## Parameters

    * `watch` - The watch storage

  ## Examples

      iex> watch = Vdr.TS.Watch.create()
      iex> {:ok, watch} = Vdr.TS.Watch.add(watch, self(), 0, "key1", :ref1)
      iex> {:ok, watch} = Vdr.TS.Watch.add(watch, self(), 0, "key2", :ref2)
      iex> watchers = Vdr.TS.Watch.all_watchers(watch)
      iex> length(watchers) == 2
      true
  """
  @spec all_watchers(t()) :: [{pid(), term()}]
  def all_watchers(%__MODULE__{key_to_pids: key_to_pids}) do
    key_to_pids
    |> Enum.flat_map(fn {_db_key, pid_map} ->
      Enum.map(pid_map, fn {pid, ref} -> {pid, ref} end)
    end)
    |> Enum.uniq()
  end
end
