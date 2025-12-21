defmodule Vdr.MapProj.Sets do
  @moduledoc """
  Set store operations for MapProj.

  Stores set values in a map structure using raw binaries.
  Each set is stored as a gb_set of binary members.
  """

  @type db :: non_neg_integer()
  @type key :: binary()
  @type element :: binary()
  @type store :: %{db() => %{key() => :gb_sets.set()}}

  @doc """
  Adds one or more members to a set.
  Returns the updated store.
  """
  @spec sadd(store(), db(), key(), [element()]) :: store()
  def sadd(store, db, key, members) when is_list(members) do
    db_map = Map.get(store, db, %{})

    gb_set =
      case Map.get(db_map, key) do
        nil -> :gb_sets.new()
        entries when is_tuple(entries) -> entries
      end

    new_gb_set = Enum.reduce(members, gb_set, fn member, acc -> :gb_sets.add_element(member, acc) end)

    new_db_map = Map.put(db_map, key, new_gb_set)
    Map.put(store, db, new_db_map)
  end

  @doc """
  Removes one or more members from a set.
  Returns the updated store.
  """
  @spec srem(store(), db(), key(), [element()]) :: store()
  def srem(store, db, key, members) when is_list(members) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        store

      gb_set when is_tuple(gb_set) ->
        new_gb_set =
          Enum.reduce(members, gb_set, fn member, acc ->
            :gb_sets.del_element(member, acc)
          end)

        store_entries(store, db, key, new_gb_set)
    end
  end

  @doc """
  Moves a member from one set to another.
  Returns the updated store.
  """
  @spec smove(store(), db(), key(), key(), element()) :: store()
  def smove(store, db, source_key, dest_key, member) do
    db_map = Map.get(store, db, %{})

    source_gb_set =
      case Map.get(db_map, source_key) do
        nil -> :gb_sets.new()
        entries when is_tuple(entries) -> entries
      end

    if :gb_sets.is_element(member, source_gb_set) do
      # Remove from source
      new_source_gb_set = :gb_sets.del_element(member, source_gb_set)
      store = store_entries(store, db, source_key, new_source_gb_set)

      # Add to dest
      db_map = Map.get(store, db, %{})

      dest_gb_set =
        case Map.get(db_map, dest_key) do
          nil -> :gb_sets.new()
          entries when is_tuple(entries) -> entries
        end

      new_dest_gb_set = :gb_sets.add_element(member, dest_gb_set)
      new_db_map = Map.put(db_map, dest_key, new_dest_gb_set)
      Map.put(store, db, new_db_map)
    else
      store
    end
  end

  @doc """
  Stores the union of multiple sets in the destination key.
  Returns the updated store.
  """
  @spec sunionstore(store(), db(), key(), [key()]) :: store()
  def sunionstore(store, db, dest_key, source_keys) when is_list(source_keys) do
    db_map = Map.get(store, db, %{})

    sets =
      Enum.map(source_keys, fn source_key ->
        case Map.get(db_map, source_key) do
          nil -> :gb_sets.new()
          entries when is_tuple(entries) -> entries
        end
      end)

    union_gb_set = :gb_sets.union(sets)

    # Delete destination first
    store = Vdr.MapProj.Common.del(store, db, dest_key)

    store_entries(store, db, dest_key, union_gb_set)
  end

  @doc """
  Stores the intersection of multiple sets in the destination key.
  Returns the updated store.
  """
  @spec sinterstore(store(), db(), key(), [key()]) :: store()
  def sinterstore(store, db, dest_key, source_keys) when is_list(source_keys) do
    # Delete destination first
    store = Vdr.MapProj.Common.del(store, db, dest_key)

    db_map = Map.get(store, db, %{})

    sets =
      Enum.map(source_keys, fn source_key ->
        case Map.get(db_map, source_key) do
          nil -> :gb_sets.new()
          entries when is_tuple(entries) -> entries
        end
      end)

    intersection_gb_set =
      case sets do
        [] -> :gb_sets.new()
        _ -> :gb_sets.intersection(sets)
      end

    store_entries(store, db, dest_key, intersection_gb_set)
  end

  @doc """
  Stores the difference of multiple sets in the destination key.
  Returns the updated store.
  """
  @spec sdiffstore(store(), db(), key(), [key()]) :: store()
  def sdiffstore(store, db, dest_key, source_keys) when is_list(source_keys) do
    # Delete destination first
    store = Vdr.MapProj.Common.del(store, db, dest_key)

    db_map = Map.get(store, db, %{})

    difference_gb_set =
      case source_keys do
        [] ->
          :gb_sets.new()

        [first_key | rest_keys] ->
          first_gb_set =
            case Map.get(db_map, first_key) do
              nil -> :gb_sets.new()
              entries when is_tuple(entries) -> entries
            end

          Enum.reduce(rest_keys, first_gb_set, fn key, acc ->
            case Map.get(db_map, key) do
              nil -> acc
              entries when is_tuple(entries) -> :gb_sets.subtract(acc, entries)
            end
          end)
      end

    store_entries(store, db, dest_key, difference_gb_set)
  end

  @doc """
  Gets all members of a set.
  """
  @spec smembers(store(), db(), key()) :: [binary()]
  def smembers(store, db, key) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil -> []
      gb_set when is_tuple(gb_set) -> :gb_sets.to_list(gb_set)
      _ -> []
    end
  end

  @doc """
  Checks if a member exists in a set.
  """
  @spec sismember(store(), db(), key(), binary()) :: boolean()
  def sismember(store, db, key, member) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil -> false
      gb_set when is_tuple(gb_set) -> :gb_sets.is_element(member, gb_set)
      _ -> false
    end
  end

  @doc """
  Returns the number of members in a set.
  """
  @spec scard(store(), db(), key()) :: non_neg_integer()
  def scard(store, db, key) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil -> 0
      gb_set when is_tuple(gb_set) -> :gb_sets.size(gb_set)
      _ -> 0
    end
  end

  @doc """
  Creates a stream of set members matching the filter function.

  The filter function receives each member and returns true/false.
  """
  @spec select_stream(store(), db(), key(), (binary() -> boolean())) :: Enumerable.t()
  def select_stream(store, db, key, filter_fun) when is_function(filter_fun, 1) do
    members = smembers(store, db, key)
    Stream.filter(members, filter_fun)
  end

  @doc """
  Creates a reverse stream of set members matching the filter function.

  The filter function receives each member and returns true/false.
  """
  @spec select_rev_stream(store(), db(), key(), (binary() -> boolean())) :: Enumerable.t()
  def select_rev_stream(store, db, key, filter_fun) when is_function(filter_fun, 1) do
    members = smembers(store, db, key)

    members
    |> Enum.reverse()
    |> Stream.filter(filter_fun)
  end

  # Private helpers

  @spec store_entries(store(), db(), key(), :gb_sets.set()) :: store()
  defp store_entries(store, db, key, gb_set) do
    if :gb_sets.size(gb_set) == 0 do
      # Remove the key when the set is empty
      case Map.get(store, db) do
        nil ->
          store

        db_map ->
          new_db_map = Map.delete(db_map, key)
          Map.put(store, db, new_db_map)
      end
    else
      db_map = Map.get(store, db, %{})
      new_db_map = Map.put(db_map, key, gb_set)
      Map.put(store, db, new_db_map)
    end
  end
end
