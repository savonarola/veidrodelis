defmodule Veidrodelis.SetStore do
  @moduledoc """
  An ETS-backed store for Redis set operations.

  Uses a protected named ETS table to store set members with decoded values.
  Each entry is stored as `{{db, key, decoded_element}, nil}`.

  The decode function is called for each element to compute a decoded representation
  that is stored in the ETS key for efficient matching and ordering.
  """

  defstruct [:table, :decode_fun]

  @type t :: %__MODULE__{
          table: atom(),
          decode_fun: decode_fun()
        }

  @type db :: non_neg_integer()
  @type key :: any()
  @type element :: binary()
  @type decode_fun :: (key(), element() -> any())

  @doc """
  Creates a new set store with the given name and decode function.

  The decode function receives `(key, element)` and returns a decoded value
  that will be used as part of the ETS key for efficient matching and ordering.

  Returns a SetStore struct containing the table name and decode function.
  """
  @spec new(atom(), decode_fun()) :: t()
  def new(name, decode_fun) when is_atom(name) and is_function(decode_fun, 2) do
    :ets.new(name, [:ordered_set, :protected, :named_table])
    %__MODULE__{table: name, decode_fun: decode_fun}
  end

  @doc """
  Adds one or more members to a set.

  SADD key member [member ...]
  """
  @spec sadd(t(), db(), key(), [element()]) :: :ok
  def sadd(%__MODULE__{table: table, decode_fun: decode_fun}, db, key, members)
      when is_list(members) do
    entries =
      Enum.map(members, fn member ->
        decoded = decode_fun.(key, member)
        {{db, key, decoded}, nil}
      end)

    :ets.insert(table, entries)
    :ok
  end

  @doc """
  Removes one or more members from a set.

  SREM key member [member ...]
  """
  @spec srem(t(), db(), key(), [element()]) :: :ok
  def srem(%__MODULE__{table: table, decode_fun: decode_fun}, db, key, members)
      when is_list(members) do
    Enum.each(members, fn member ->
      decoded = decode_fun.(key, member)
      :ets.delete(table, {db, key, decoded})
    end)

    :ok
  end

  @doc """
  Moves a member from one set to another.

  SMOVE source destination member

  If the member exists in the source set, it is removed from source and added to destination.
  Returns :ok if the member was moved, :not_found if it didn't exist in source.
  """
  @spec smove(t(), db(), key(), key(), element()) :: :ok | :not_found
  def smove(%__MODULE__{table: table, decode_fun: decode_fun}, db, source_key, dest_key, member) do
    source_decoded = decode_fun.(source_key, member)
    source_ets_key = {db, source_key, source_decoded}

    case :ets.lookup(table, source_ets_key) do
      [] ->
        :not_found

      [_] ->
        # Remove from source
        :ets.delete(table, source_ets_key)

        # Add to destination
        dest_decoded = decode_fun.(dest_key, member)
        :ets.insert(table, {{db, dest_key, dest_decoded}, nil})

        :ok
    end
  end

  @doc """
  Stores the union of multiple sets in the destination key.

  SUNIONSTORE destination key [key ...]

  The destination set will contain all unique elements from all source sets.
  """
  @spec sunionstore(t(), db(), key(), [key()]) :: :ok
  def sunionstore(%__MODULE__{table: table, decode_fun: _decode_fun}, db, dest_key, source_keys)
      when is_list(source_keys) do
    # Collect all unique decoded elements from all source sets
    union_elements =
      source_keys
      |> Enum.flat_map(fn source_key ->
        fetch_set_elements(table, db, source_key)
      end)
      |> Enum.uniq()

    # Clear destination set
    clear_set(table, db, dest_key)

    # Insert union into destination
    entries =
      Enum.map(union_elements, fn decoded ->
        {{db, dest_key, decoded}, nil}
      end)

    if entries != [] do
      :ets.insert(table, entries)
    end

    :ok
  end

  @doc """
  Stores the intersection of multiple sets in the destination key.

  SINTERSTORE destination key [key ...]

  The destination set will contain only elements that exist in all source sets.
  If any source set is empty or doesn't exist, the result will be empty.
  """
  @spec sinterstore(t(), db(), key(), [key()]) :: :ok
  def sinterstore(%__MODULE__{table: table}, db, dest_key, source_keys)
      when is_list(source_keys) do
    # Get elements from all source sets
    sets =
      Enum.map(source_keys, fn source_key ->
        fetch_set_elements(table, db, source_key)
        |> MapSet.new()
      end)

    # Compute intersection
    intersection =
      case sets do
        [] ->
          MapSet.new()

        [first | rest] ->
          Enum.reduce(rest, first, fn set, acc ->
            MapSet.intersection(acc, set)
          end)
      end

    # Clear destination set
    clear_set(table, db, dest_key)

    # Insert intersection into destination
    entries =
      intersection
      |> Enum.map(fn decoded ->
        {{db, dest_key, decoded}, nil}
      end)

    if entries != [] do
      :ets.insert(table, entries)
    end

    :ok
  end

  @doc """
  Stores the difference of multiple sets in the destination key.

  SDIFFSTORE destination key [key ...]

  The destination set will contain elements that exist in the first key
  but not in any of the subsequent keys.
  """
  @spec sdiffstore(t(), db(), key(), [key()]) :: :ok
  def sdiffstore(%__MODULE__{table: table}, db, dest_key, source_keys)
      when is_list(source_keys) do
    result =
      case source_keys do
        [] ->
          MapSet.new()

        [first_key | rest_keys] ->
          first_set = fetch_set_elements(table, db, first_key) |> MapSet.new()

          # Subtract all other sets from the first
          Enum.reduce(rest_keys, first_set, fn key, acc ->
            other_set = fetch_set_elements(table, db, key) |> MapSet.new()
            MapSet.difference(acc, other_set)
          end)
      end

    # Clear destination set
    clear_set(table, db, dest_key)

    # Insert difference into destination
    entries =
      result
      |> Enum.map(fn decoded ->
        {{db, dest_key, decoded}, nil}
      end)

    if entries != [] do
      :ets.insert(table, entries)
    end

    :ok
  end

  @doc """
  Gets all members of a set as decoded values.
  """
  @spec smembers(t(), db(), key()) :: [any()]
  def smembers(%__MODULE__{table: table}, db, key) do
    fetch_set_elements(table, db, key)
  end

  @doc """
  Checks if a member exists in a set.
  """
  @spec sismember(t(), db(), key(), element()) :: boolean()
  def sismember(%__MODULE__{table: table, decode_fun: decode_fun}, db, key, member) do
    decoded = decode_fun.(key, member)

    case :ets.lookup(table, {db, key, decoded}) do
      [] -> false
      [_] -> true
    end
  end

  @doc """
  Returns the number of members in a set.
  """
  @spec scard(t(), db(), key()) :: non_neg_integer()
  def scard(%__MODULE__{table: table}, db, key) do
    # Use matchspec to count efficiently
    match_spec = [
      {{{db, key, :_}, :_}, [], [true]}
    ]

    :ets.select_count(table, match_spec)
  end

  @doc """
  Deletes an entire set.
  """
  @spec del(t(), db(), key()) :: :ok
  def del(%__MODULE__{table: table}, db, key) do
    clear_set(table, db, key)
    :ok
  end

  @doc """
  Destroys the ETS table and releases resources.
  """
  @spec destroy(t()) :: :ok
  def destroy(%__MODULE__{table: table}) do
    if :ets.whereis(table) != :undefined do
      :ets.delete(table)
    end

    :ok
  end

  # Private helpers

  # Fetches all decoded elements from a set using matchspec
  @spec fetch_set_elements(:ets.table(), db(), key()) :: [any()]
  defp fetch_set_elements(table, db, key) do
    # Use matchspec with bounded {db, key, ...} part
    match_spec = [
      {{{db, key, :"$1"}, :_}, [], [:"$1"]}
    ]

    :ets.select(table, match_spec)
  end

  # Clears all elements from a set
  @spec clear_set(:ets.table(), db(), key()) :: :ok
  defp clear_set(table, db, key) do
    # Use matchspec to efficiently delete all elements with bounded {db, key, ...}
    match_spec = [
      {{{db, key, :_}, :_}, [], [true]}
    ]

    :ets.select_delete(table, match_spec)
    :ok
  end
end

