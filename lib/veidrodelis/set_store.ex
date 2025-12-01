defmodule Vdr.SetStore do
  @moduledoc """
  An ETS-backed store for Redis set operations.

  Uses a shared ETS table to store set members with decoded values.
  Each entry is stored as `{{db, key, :set, decoded_set_entry}, nil}`.

  The decode function is called for each element to compute a decoded representation
  that is stored in the ETS key for efficient matching and ordering.
  """

  alias Vdr.CommonStore

  defstruct [:tid, :decode_fun]

  @type t :: %__MODULE__{
          tid: :ets.tid(),
          decode_fun: decode_fun()
        }

  @type db :: non_neg_integer()
  @type key :: any()
  @type element :: binary()
  @type decode_fun :: (key(), element() -> any())

  @doc """
  Creates a new set store with the given ETS table and decode function.

  The decode function receives `(key, element)` and returns a decoded value
  that will be used as part of the ETS key for efficient matching and ordering.

  Returns a SetStore struct containing the table id and decode function.
  """
  @spec new(:ets.tid(), decode_fun()) :: t()
  def new(tid, decode_fun) when is_function(decode_fun, 2) do
    %__MODULE__{tid: tid, decode_fun: decode_fun}
  end

  @doc """
  Adds one or more members to a set.

  SADD key member [member ...]
  """
  @spec sadd(t(), db(), key(), [element()]) :: :ok
  def sadd(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, members)
      when is_list(members) do
    entries =
      Enum.map(members, fn member ->
        decoded = decode_fun.(key, member)
        {{db, key, :set, decoded}, nil}
      end)

    :ets.insert(tid, entries)
    :ok
  end

  @doc """
  Removes one or more members from a set.

  SREM key member [member ...]
  """
  @spec srem(t(), db(), key(), [element()]) :: :ok
  def srem(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, members)
      when is_list(members) do
    Enum.each(members, fn member ->
      decoded = decode_fun.(key, member)
      :ets.delete(tid, {db, key, :set, decoded})
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
  def smove(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, source_key, dest_key, member) do
    source_decoded = decode_fun.(source_key, member)
    source_ets_key = {db, source_key, :set, source_decoded}

    case :ets.lookup(tid, source_ets_key) do
      [] ->
        :not_found

      [_] ->
        # Remove from source
        :ets.delete(tid, source_ets_key)

        # Add to destination
        dest_decoded = decode_fun.(dest_key, member)
        :ets.insert(tid, {{db, dest_key, :set, dest_decoded}, nil})

        :ok
    end
  end

  @doc """
  Stores the union of multiple sets in the destination key.

  SUNIONSTORE destination key [key ...]

  The destination set will contain all unique elements from all source sets.
  """

  ## TODO
  ## Do not fetch all elements into memory
  @spec sunionstore(t(), db(), key(), [key()]) :: :ok
  def sunionstore(%__MODULE__{tid: tid, decode_fun: _decode_fun}, db, dest_key, source_keys)
      when is_list(source_keys) do
    # Collect all unique decoded elements from all source sets first
    # (before deleting destination, in case it's also a source)
    union_elements =
      source_keys
      |> Enum.flat_map(fn source_key ->
        fetch_set_elements(tid, db, source_key)
      end)
      |> Enum.uniq()

    # Delete previous key in case it exists (destructive op)
    CommonStore.del(tid, db, dest_key)

    # Insert union into destination
    entries =
      Enum.map(union_elements, fn decoded ->
        {{db, dest_key, :set, decoded}, nil}
      end)

    if entries != [] do
      :ets.insert(tid, entries)
    end

    :ok
  end

  @doc """
  Stores the intersection of multiple sets in the destination key.

  SINTERSTORE destination key [key ...]

  The destination set will contain only elements that exist in all source sets.
  If any source set is empty or doesn't exist, the result will be empty.
  """
  ## TODO
  ## Do not fetch all elements into memory
  @spec sinterstore(t(), db(), key(), [key()]) :: :ok
  def sinterstore(%__MODULE__{tid: tid}, db, dest_key, source_keys)
      when is_list(source_keys) do
    # Delete previous key in case it exists (destructive op)
    CommonStore.del(tid, db, dest_key)

    # Get elements from all source sets
    sets =
      Enum.map(source_keys, fn source_key ->
        fetch_set_elements(tid, db, source_key)
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

    # Insert intersection into destination
    entries =
      intersection
      |> Enum.map(fn decoded ->
        {{db, dest_key, :set, decoded}, nil}
      end)

    if entries != [] do
      :ets.insert(tid, entries)
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
  def sdiffstore(%__MODULE__{tid: tid}, db, dest_key, source_keys)
      when is_list(source_keys) do
    # Delete previous key in case it exists (destructive op)
    CommonStore.del(tid, db, dest_key)

    result =
      case source_keys do
        [] ->
          MapSet.new()

        [first_key | rest_keys] ->
          first_set = fetch_set_elements(tid, db, first_key) |> MapSet.new()

          # Subtract all other sets from the first
          Enum.reduce(rest_keys, first_set, fn key, acc ->
            other_set = fetch_set_elements(tid, db, key) |> MapSet.new()
            MapSet.difference(acc, other_set)
          end)
      end

    # Insert difference into destination
    entries =
      result
      |> Enum.map(fn decoded ->
        {{db, dest_key, :set, decoded}, nil}
      end)

    if entries != [] do
      :ets.insert(tid, entries)
    end

    :ok
  end

  @doc """
  Gets all members of a set as decoded values.
  """
  @spec smembers(t(), db(), key()) :: [any()]
  def smembers(%__MODULE__{tid: tid}, db, key) do
    fetch_set_elements(tid, db, key)
  end

  @doc """
  Checks if a member exists in a set.
  """
  @spec sismember(t(), db(), key(), element()) :: boolean()
  def sismember(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, key, member) do
    decoded = decode_fun.(key, member)

    case :ets.lookup(tid, {db, key, :set, decoded}) do
      [] -> false
      [_] -> true
    end
  end

  @doc """
  Returns the number of members in a set.
  """
  @spec scard(t(), db(), key()) :: non_neg_integer()
  def scard(%__MODULE__{tid: tid}, db, key) do
    # Use matchspec to count efficiently
    match_spec = [
      {{{db, key, :set, :_}, :_}, [], [true]}
    ]

    :ets.select_count(tid, match_spec)
  end

  @doc """
  Deletes an entire set.
  """
  @spec del(t(), db(), key()) :: :ok
  def del(%__MODULE__{tid: tid}, db, key) do
    CommonStore.del(tid, db, key)
  end

  # Private helpers

  # Fetches all decoded elements from a set using matchspec
  @spec fetch_set_elements(:ets.table(), db(), key()) :: [any()]
  defp fetch_set_elements(table, db, key) do
    # Use matchspec with bounded {db, key, :set, ...} part
    match_spec = [
      {{{db, key, :set, :"$1"}, :_}, [], [:"$1"]}
    ]

    :ets.select(table, match_spec)
  end
end
