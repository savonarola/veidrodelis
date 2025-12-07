defmodule Vdr.MapProj.Sets do
  @moduledoc """
  Set store operations for MapProj.

  Stores set values in a map structure.
  Each set is stored as `%Set{entries: gb_set()}`.
  """

  defmodule Set do
    @moduledoc false
    defstruct [:entries]

    @type t :: %__MODULE__{
            entries: :gb_sets.set()
          }
  end

  defstruct [:decode_fun]

  @type t :: %__MODULE__{
          decode_fun: decode_fun()
        }

  @type db :: non_neg_integer()
  @type key :: any()
  @type element :: binary()
  @type decode_fun :: (key(), element() -> any())
  @type store :: %{db() => %{key() => Set.t()}}

  @doc """
  Creates a new set store configuration with the given decode function.
  """
  @spec new(decode_fun()) :: t()
  def new(decode_fun) when is_function(decode_fun, 2) do
    %__MODULE__{decode_fun: decode_fun}
  end

  @doc """
  Adds one or more members to a set.
  Returns the updated store.
  """
  @spec sadd(store(), t(), db(), key(), [element()]) :: store()
  def sadd(store, %__MODULE__{decode_fun: decode_fun}, db, key, members)
      when is_list(members) do
    db_map = Map.get(store, db, %{})

    gb_set =
      case Map.get(db_map, key) do
        nil -> :gb_sets.new()
        %Set{entries: entries} -> entries
      end

    new_gb_set =
      Enum.reduce(members, gb_set, fn member, acc ->
        decoded = decode_fun.(key, member)
        :gb_sets.add_element(decoded, acc)
      end)

    set_entry = %Set{entries: new_gb_set}
    new_db_map = Map.put(db_map, key, set_entry)
    Map.put(store, db, new_db_map)
  end

  @doc """
  Removes one or more members from a set.
  Returns the updated store.
  """
  @spec srem(store(), t(), db(), key(), [element()]) :: store()
  def srem(store, %__MODULE__{decode_fun: decode_fun}, db, key, members)
      when is_list(members) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        store

      %Set{entries: gb_set} ->
        new_gb_set =
          Enum.reduce(members, gb_set, fn member, acc ->
            decoded = decode_fun.(key, member)
            :gb_sets.del_element(decoded, acc)
          end)

        store_entries(store, db, key, new_gb_set)
    end
  end

  @doc """
  Moves a member from one set to another.
  Returns the updated store.
  """
  @spec smove(store(), t(), db(), key(), key(), element()) :: store()
  def smove(store, %__MODULE__{decode_fun: decode_fun}, db, source_key, dest_key, member) do
    db_map = Map.get(store, db, %{})
    source_decoded = decode_fun.(source_key, member)

    source_gb_set =
      case Map.get(db_map, source_key) do
        nil -> :gb_sets.new()
        %Set{entries: entries} -> entries
      end

    if :gb_sets.is_element(source_decoded, source_gb_set) do
      # Remove from source
      new_source_gb_set = :gb_sets.del_element(source_decoded, source_gb_set)
      store = store_entries(store, db, source_key, new_source_gb_set)

      # Add to dest
      db_map = Map.get(store, db, %{})

      dest_gb_set =
        case Map.get(db_map, dest_key) do
          nil -> :gb_sets.new()
          %Set{entries: entries} -> entries
        end

      dest_decoded = decode_fun.(dest_key, member)
      new_dest_gb_set = :gb_sets.add_element(dest_decoded, dest_gb_set)
      set_entry = %Set{entries: new_dest_gb_set}
      new_db_map = Map.put(db_map, dest_key, set_entry)
      Map.put(store, db, new_db_map)
    else
      store
    end
  end

  @doc """
  Stores the union of multiple sets in the destination key.
  Returns the updated store.
  """
  @spec sunionstore(store(), t(), db(), key(), [key()]) :: store()
  def sunionstore(store, %__MODULE__{}, db, dest_key, source_keys)
      when is_list(source_keys) do
    db_map = Map.get(store, db, %{})

    sets =
      Enum.map(source_keys, fn source_key ->
        case Map.get(db_map, source_key) do
          nil -> :gb_sets.new()
          %Set{entries: entries} -> entries
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
  @spec sinterstore(store(), t(), db(), key(), [key()]) :: store()
  def sinterstore(store, %__MODULE__{}, db, dest_key, source_keys)
      when is_list(source_keys) do
    # Delete destination first
    store = Vdr.MapProj.Common.del(store, db, dest_key)

    db_map = Map.get(store, db, %{})

    sets =
      Enum.map(source_keys, fn source_key ->
        case Map.get(db_map, source_key) do
          nil -> :gb_sets.new()
          %Set{entries: entries} -> entries
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
  @spec sdiffstore(store(), t(), db(), key(), [key()]) :: store()
  def sdiffstore(store, %__MODULE__{}, db, dest_key, source_keys)
      when is_list(source_keys) do
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
              %Set{entries: entries} -> entries
            end

          Enum.reduce(rest_keys, first_gb_set, fn key, acc ->
            case Map.get(db_map, key) do
              nil -> acc
              %Set{entries: entries} -> :gb_sets.subtract(acc, entries)
            end
          end)
      end

    store_entries(store, db, dest_key, difference_gb_set)
  end

  @doc """
  Gets all members of a set as decoded values.
  """
  @spec smembers(store(), db(), key()) :: [any()]
  def smembers(store, db, key) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil -> []
      %Set{entries: gb_set} -> :gb_sets.to_list(gb_set)
      _ -> []
    end
  end

  @doc """
  Checks if a member exists in a set.
  Note: This requires the decoded member value.
  """
  @spec sismember(store(), db(), key(), any()) :: boolean()
  def sismember(store, db, key, decoded_member) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil -> false
      %Set{entries: gb_set} -> :gb_sets.is_element(decoded_member, gb_set)
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
      %Set{entries: gb_set} -> :gb_sets.size(gb_set)
      _ -> 0
    end
  end

  @doc """
  Creates a stream of set members matching the filter function.

  The filter function receives each member and returns true/false.
  """
  @spec select_stream(store(), db(), key(), (any() -> boolean())) :: Enumerable.t()
  def select_stream(store, db, key, filter_fun) when is_function(filter_fun, 1) do
    members = smembers(store, db, key)
    Stream.filter(members, filter_fun)
  end

  @doc """
  Creates a reverse stream of set members matching the filter function.

  The filter function receives each member and returns true/false.
  """
  @spec select_rev_stream(store(), db(), key(), (any() -> boolean())) :: Enumerable.t()
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
        nil -> store
        db_map ->
          new_db_map = Map.delete(db_map, key)
          Map.put(store, db, new_db_map)
      end
    else
      db_map = Map.get(store, db, %{})
      set_entry = %Set{entries: gb_set}
      new_db_map = Map.put(db_map, key, set_entry)
      Map.put(store, db, new_db_map)
    end
  end
end
