defmodule Vdr.TS.Watch do
  @moduledoc """
  Watch storage for tracking key-based and prefix-based subscriptions with database scoping.

  Allows multiple processes to register watches for specific keys and key prefixes
  in specific databases, associating each watch with a reference value.

  ## Internal Structure

  The watch storage uses these collections:
  1. `key_to_pids`: `%{db => %{key => %{pid => ref}}}` - maps database to key to pid-to-ref mappings
  2. `pid_to_keys`: `%{pid => MapSet.t({db, key})}` - maps pids to sets of database-scoped keys
  3. `prefix_tree`: Rust radix tree storing watcher indexes by database-scoped prefix
  4. `prefix_to_pids`: `%{db => %{prefix => %{pid => ref}}}` - maps database to prefix to pid-to-ref mappings
  5. `pid_to_prefixes`: `%{pid => MapSet.t({db, prefix})}` - maps pids to database-scoped prefixes
  6. `pid_by_idx` and `idx_by_pid`: maps between pids and integer indexes stored in the Rust tree

  ## Example

      watch = Vdr.TS.Watch.create()

      {:ok, watch} = Vdr.TS.Watch.add(watch, self(), 0, "user:123", :my_ref)
      {:ok, watch} = Vdr.TS.Watch.add_prefix(watch, self(), 0, "team:42:", :prefix_ref)

      [{:my_ref, _pid}] = Vdr.TS.Watch.lookup(watch, 0, "user:123")
      [{:prefix_ref, _pid}] = Vdr.TS.Watch.lookup_prefix(watch, 0, "team:42:user:1")

      {:ok, watch, _remaining} = Vdr.TS.Watch.delete(watch, self(), 0, "user:123")
      {:ok, watch, _remaining} = Vdr.TS.Watch.delete_prefix(watch, self(), 0, "team:42:")

      watch = Vdr.TS.Watch.delete_all(watch, self())
  """

  @type db_key :: {non_neg_integer(), String.t()}
  @type watcher_ref :: term()

  @type t :: %__MODULE__{
          key_to_pids: %{non_neg_integer() => %{String.t() => %{pid() => watcher_ref()}}},
          pid_to_keys: %{pid() => MapSet.t(db_key())},
          prefix_tree: reference(),
          prefix_to_pids: %{non_neg_integer() => %{String.t() => %{pid() => watcher_ref()}}},
          pid_to_prefixes: %{pid() => MapSet.t(db_key())},
          pid_by_idx: %{integer() => pid()},
          idx_by_pid: %{pid() => integer()}
        }

  defstruct key_to_pids: %{},
            pid_to_keys: %{},
            prefix_tree: nil,
            prefix_to_pids: %{},
            pid_to_prefixes: %{},
            pid_by_idx: %{},
            idx_by_pid: %{}

  @doc """
  Creates a new empty watch storage.

  ## Examples

      iex> watch = Vdr.TS.Watch.create()
      iex> is_struct(watch, Vdr.TS.Watch)
      true
  """
  @spec create() :: t()
  def create do
    %__MODULE__{prefix_tree: Vdr.TS.watch_prefix_tree_create()}
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
    if get_in(watch.key_to_pids, [db, key, pid]) do
      {:error, :already_registered}
    else
      key_to_pids =
        watch.key_to_pids
        |> Map.update(db, %{key => %{pid => ref}}, fn db_map ->
          Map.update(db_map, key, %{pid => ref}, fn pid_map ->
            Map.put(pid_map, pid, ref)
          end)
        end)

      db_key = {db, key}

      pid_to_keys =
        Map.update(watch.pid_to_keys, pid, MapSet.new([db_key]), fn keys ->
          MapSet.put(keys, db_key)
        end)

      {:ok, %{watch | key_to_pids: key_to_pids, pid_to_keys: pid_to_keys}}
    end
  end

  @doc """
  Adds a prefix watch entry for the given pid, database, prefix, and ref.

  Returns `{:ok, updated_watch}` on success, or `{:error, reason}` if the prefix
  is already registered for this pid in this database.

  ## Parameters

    * `watch` - The watch storage
    * `pid` - The process identifier
    * `db` - The database number
    * `prefix` - The key prefix to watch (string)
    * `ref` - The reference value to associate with this watch

  ## Examples

      iex> watch = Vdr.TS.Watch.create()
      iex> {:ok, watch} = Vdr.TS.Watch.add_prefix(watch, self(), 0, "user:", :ref1)
      iex> {:error, :already_registered} = Vdr.TS.Watch.add_prefix(watch, self(), 0, "user:", :ref2)
  """
  @spec add_prefix(t(), pid(), non_neg_integer(), String.t(), term()) ::
          {:ok, t()} | {:error, atom()}
  def add_prefix(%__MODULE__{} = watch, pid, db, prefix, ref)
      when is_integer(db) and is_binary(prefix) do
    if get_in(watch.prefix_to_pids, [db, prefix, pid]) do
      {:error, :already_registered}
    else
      {idx, pid_by_idx, idx_by_pid} = ensure_pid_idx(watch, pid)

      :ok = Vdr.TS.watch_prefix_tree_insert(watch.prefix_tree, db, prefix, idx)

      prefix_to_pids =
        watch.prefix_to_pids
        |> Map.update(db, %{prefix => %{pid => ref}}, fn db_map ->
          Map.update(db_map, prefix, %{pid => ref}, fn pid_map ->
            Map.put(pid_map, pid, ref)
          end)
        end)

      db_prefix = {db, prefix}

      pid_to_prefixes =
        Map.update(watch.pid_to_prefixes, pid, MapSet.new([db_prefix]), fn prefixes ->
          MapSet.put(prefixes, db_prefix)
        end)

      {:ok,
       %{
         watch
         | prefix_to_pids: prefix_to_pids,
           pid_to_prefixes: pid_to_prefixes,
           pid_by_idx: pid_by_idx,
           idx_by_pid: idx_by_pid
       }}
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
    unless get_in(watch.key_to_pids, [db, key, pid]) do
      {:error, :not_found}
    else
      key_to_pids = delete_pid_from_db_value(watch.key_to_pids, db, key, pid)
      db_key = {db, key}

      pid_to_keys =
        Map.update(watch.pid_to_keys, pid, MapSet.new(), fn keys ->
          new_keys = MapSet.delete(keys, db_key)

          if MapSet.size(new_keys) == 0 do
            :delete_pid
          else
            new_keys
          end
        end)

      exact_count =
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

      remaining_count = exact_count + prefix_watch_count(watch, pid)

      {:ok, %{watch | key_to_pids: key_to_pids, pid_to_keys: pid_to_keys}, remaining_count}
    end
  end

  @doc """
  Deletes a single prefix watch entry for the given pid, database, and prefix.

  Returns `{:ok, updated_watch, remaining_count}` on success, where `remaining_count`
  is the number of watches remaining for the pid. Returns `{:error, reason}` if the
  prefix watch entry does not exist.

  ## Parameters

    * `watch` - The watch storage
    * `pid` - The process identifier
    * `db` - The database number
    * `prefix` - The prefix to unwatch

  ## Examples

      iex> watch = Vdr.TS.Watch.create()
      iex> {:ok, watch} = Vdr.TS.Watch.add_prefix(watch, self(), 0, "user:", :ref1)
      iex> {:ok, watch, 0} = Vdr.TS.Watch.delete_prefix(watch, self(), 0, "user:")
      iex> {:error, :not_found} = Vdr.TS.Watch.delete_prefix(watch, self(), 0, "user:")
  """
  @spec delete_prefix(t(), pid(), non_neg_integer(), String.t()) ::
          {:ok, t(), non_neg_integer()} | {:error, atom()}
  def delete_prefix(%__MODULE__{} = watch, pid, db, prefix)
      when is_integer(db) and is_binary(prefix) do
    unless get_in(watch.prefix_to_pids, [db, prefix, pid]) do
      {:error, :not_found}
    else
      idx = Map.fetch!(watch.idx_by_pid, pid)
      :ok = Vdr.TS.watch_prefix_tree_delete(watch.prefix_tree, db, prefix, idx)

      prefix_to_pids = delete_pid_from_db_value(watch.prefix_to_pids, db, prefix, pid)
      db_prefix = {db, prefix}

      pid_to_prefixes =
        Map.update(watch.pid_to_prefixes, pid, MapSet.new(), fn prefixes ->
          new_prefixes = MapSet.delete(prefixes, db_prefix)

          if MapSet.size(new_prefixes) == 0 do
            :delete_pid
          else
            new_prefixes
          end
        end)

      prefix_count =
        case Map.get(pid_to_prefixes, pid) do
          :delete_pid -> 0
          prefixes when is_struct(prefixes, MapSet) -> MapSet.size(prefixes)
        end

      {pid_to_prefixes, pid_by_idx, idx_by_pid} =
        if prefix_count == 0 do
          {
            Map.delete(pid_to_prefixes, pid),
            Map.delete(watch.pid_by_idx, idx),
            Map.delete(watch.idx_by_pid, pid)
          }
        else
          {pid_to_prefixes, watch.pid_by_idx, watch.idx_by_pid}
        end

      remaining_count = exact_watch_count(watch, pid) + prefix_count

      {:ok,
       %{
         watch
         | prefix_to_pids: prefix_to_pids,
           pid_to_prefixes: pid_to_prefixes,
           pid_by_idx: pid_by_idx,
           idx_by_pid: idx_by_pid
       }, remaining_count}
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
    db_keys = Map.get(watch.pid_to_keys, pid, MapSet.new())
    db_prefixes = Map.get(watch.pid_to_prefixes, pid, MapSet.new())
    idx = Map.get(watch.idx_by_pid, pid)

    key_to_pids =
      Enum.reduce(db_keys, watch.key_to_pids, fn {db, key}, acc ->
        delete_pid_from_db_value(acc, db, key, pid)
      end)

    prefix_to_pids =
      Enum.reduce(db_prefixes, watch.prefix_to_pids, fn {db, prefix}, acc ->
        if idx, do: Vdr.TS.watch_prefix_tree_delete(watch.prefix_tree, db, prefix, idx)
        delete_pid_from_db_value(acc, db, prefix, pid)
      end)

    %{
      watch
      | key_to_pids: key_to_pids,
        pid_to_keys: Map.delete(watch.pid_to_keys, pid),
        prefix_to_pids: prefix_to_pids,
        pid_to_prefixes: Map.delete(watch.pid_to_prefixes, pid),
        pid_by_idx: if(idx, do: Map.delete(watch.pid_by_idx, idx), else: watch.pid_by_idx),
        idx_by_pid: Map.delete(watch.idx_by_pid, pid)
    }
  end

  @doc """
  Looks up all watches for the given database and exact key.

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
    case get_in(watch.key_to_pids, [db, key]) do
      nil -> []
      pid_map -> Enum.map(pid_map, fn {pid, ref} -> {ref, pid} end)
    end
  end

  @doc """
  Looks up all prefix watches matching the given database and key.

  Returns a list of `{ref, pid}` tuples for all processes watching a prefix
  that the key starts with in the specified database.

  ## Parameters

    * `watch` - The watch storage
    * `db` - The database number
    * `key` - The key to lookup

  ## Examples

      iex> watch = Vdr.TS.Watch.create()
      iex> {:ok, watch} = Vdr.TS.Watch.add_prefix(watch, self(), 0, "user:", :ref1)
      iex> [{:ref1, _pid}] = Vdr.TS.Watch.lookup_prefix(watch, 0, "user:123")
      iex> [] = Vdr.TS.Watch.lookup_prefix(watch, 0, "other:123")
  """
  @spec lookup_prefix(t(), non_neg_integer(), String.t()) :: [{term(), pid()}]
  def lookup_prefix(%__MODULE__{} = watch, db, key) when is_integer(db) and is_binary(key) do
    watch.prefix_tree
    |> Vdr.TS.watch_prefix_tree_lookup(db, key)
    |> Enum.flat_map(fn idx ->
      case Map.get(watch.pid_by_idx, idx) do
        nil ->
          []

        pid ->
          watch.pid_to_prefixes
          |> Map.get(pid, MapSet.new())
          |> Enum.flat_map(fn
            {^db, prefix} ->
              if String.starts_with?(key, prefix) do
                case get_in(watch.prefix_to_pids, [db, prefix, pid]) do
                  nil -> []
                  ref -> [{ref, pid}]
                end
              else
                []
              end

            _ ->
              []
          end)
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  Returns all unique `{pid, ref}` pairs across all exact and prefix watches.

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
  def all_watchers(%__MODULE__{} = watch) do
    exact_watchers =
      watch.key_to_pids
      |> Enum.flat_map(fn {_db, key_map} ->
        Enum.flat_map(key_map, fn {_key, pid_map} ->
          Enum.map(pid_map, fn {pid, ref} -> {pid, ref} end)
        end)
      end)

    prefix_watchers =
      watch.prefix_to_pids
      |> Enum.flat_map(fn {_db, prefix_map} ->
        Enum.flat_map(prefix_map, fn {_prefix, pid_map} ->
          Enum.map(pid_map, fn {pid, ref} -> {pid, ref} end)
        end)
      end)

    (exact_watchers ++ prefix_watchers)
    |> Enum.uniq()
  end

  @doc """
  Returns all unique `{ref, pid}` pairs for exact and prefix watches in a specific database.

  This is useful for database-wide operations like FLUSHDB.

  ## Parameters

    * `watch` - The watch storage
    * `db` - The database number

  ## Examples

      iex> watch = Vdr.TS.Watch.create()
      iex> {:ok, watch} = Vdr.TS.Watch.add(watch, self(), 0, "key1", :ref1)
      iex> {:ok, watch} = Vdr.TS.Watch.add(watch, self(), 1, "key2", :ref2)
      iex> watchers = Vdr.TS.Watch.lookup_by_db(watch, 0)
      iex> length(watchers) == 1
      true
  """
  @spec lookup_by_db(t(), non_neg_integer()) :: [{term(), pid()}]
  def lookup_by_db(%__MODULE__{} = watch, db) when is_integer(db) do
    exact_watchers =
      case Map.get(watch.key_to_pids, db) do
        nil ->
          []

        key_map ->
          key_map
          |> Enum.flat_map(fn {_key, pid_map} ->
            Enum.map(pid_map, fn {pid, ref} -> {ref, pid} end)
          end)
      end

    prefix_watchers =
      case Map.get(watch.prefix_to_pids, db) do
        nil ->
          []

        prefix_map ->
          prefix_map
          |> Enum.flat_map(fn {_prefix, pid_map} ->
            Enum.map(pid_map, fn {pid, ref} -> {ref, pid} end)
          end)
      end

    (exact_watchers ++ prefix_watchers)
    |> Enum.uniq()
  end

  defp ensure_pid_idx(%__MODULE__{} = watch, pid) do
    case Map.get(watch.idx_by_pid, pid) do
      nil ->
        idx = System.unique_integer([:positive])
        {idx, Map.put(watch.pid_by_idx, idx, pid), Map.put(watch.idx_by_pid, pid, idx)}

      idx ->
        {idx, watch.pid_by_idx, watch.idx_by_pid}
    end
  end

  defp exact_watch_count(%__MODULE__{} = watch, pid) do
    watch.pid_to_keys
    |> Map.get(pid, MapSet.new())
    |> MapSet.size()
  end

  defp prefix_watch_count(%__MODULE__{} = watch, pid) do
    watch.pid_to_prefixes
    |> Map.get(pid, MapSet.new())
    |> MapSet.size()
  end

  defp delete_pid_from_db_value(value_to_pids, db, value, pid) do
    value_to_pids
    |> update_in([db, value], fn pid_map ->
      new_pid_map = Map.delete(pid_map || %{}, pid)
      if map_size(new_pid_map) == 0, do: :delete, else: new_pid_map
    end)
    |> then(fn updated ->
      if get_in(updated, [db, value]) == :delete do
        new_db_map = Map.delete(updated[db] || %{}, value)

        if map_size(new_db_map) == 0 do
          Map.delete(updated, db)
        else
          Map.put(updated, db, new_db_map)
        end
      else
        updated
      end
    end)
  end
end
