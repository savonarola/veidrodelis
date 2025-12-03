defmodule Vdr.ETSProj.Write.Sets do
  @moduledoc """
  Write operations for Redis set store.

  Uses a shared ETS table to store set members with decoded values.
  Each entry is stored as `{{db, key, :set, decoded_set_entry}, nil}`.
  """

  alias Vdr.ETSProj.Write.Common

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
  """
  @spec new(:ets.tid(), decode_fun()) :: t()
  def new(tid, decode_fun) when is_function(decode_fun, 2) do
    %__MODULE__{tid: tid, decode_fun: decode_fun}
  end

  @doc """
  Adds one or more members to a set.
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
  """
  @spec smove(t(), db(), key(), key(), element()) :: :ok | :not_found
  def smove(%__MODULE__{tid: tid, decode_fun: decode_fun}, db, source_key, dest_key, member) do
    source_decoded = decode_fun.(source_key, member)
    source_ets_key = {db, source_key, :set, source_decoded}

    case :ets.lookup(tid, source_ets_key) do
      [] ->
        :not_found

      [_] ->
        :ets.delete(tid, source_ets_key)

        dest_decoded = decode_fun.(dest_key, member)
        :ets.insert(tid, {{db, dest_key, :set, dest_decoded}, nil})

        :ok
    end
  end

  @doc """
  Stores the union of multiple sets in the destination key.
  """
  @spec sunionstore(t(), db(), key(), [key()]) :: :ok
  def sunionstore(%__MODULE__{tid: tid}, db, dest_key, source_keys)
      when is_list(source_keys) do
    union_elements =
      source_keys
      |> Enum.flat_map(fn source_key ->
        fetch_set_elements(tid, db, source_key)
      end)
      |> Enum.uniq()

    Common.del(tid, db, dest_key)

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
  """
  @spec sinterstore(t(), db(), key(), [key()]) :: :ok
  def sinterstore(%__MODULE__{tid: tid}, db, dest_key, source_keys)
      when is_list(source_keys) do
    Common.del(tid, db, dest_key)

    sets =
      Enum.map(source_keys, fn source_key ->
        fetch_set_elements(tid, db, source_key)
        |> MapSet.new()
      end)

    intersection =
      case sets do
        [] ->
          MapSet.new()

        [first | rest] ->
          Enum.reduce(rest, first, fn set, acc ->
            MapSet.intersection(acc, set)
          end)
      end

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
  """
  @spec sdiffstore(t(), db(), key(), [key()]) :: :ok
  def sdiffstore(%__MODULE__{tid: tid}, db, dest_key, source_keys)
      when is_list(source_keys) do
    Common.del(tid, db, dest_key)

    result =
      case source_keys do
        [] ->
          MapSet.new()

        [first_key | rest_keys] ->
          first_set = fetch_set_elements(tid, db, first_key) |> MapSet.new()

          Enum.reduce(rest_keys, first_set, fn key, acc ->
            other_set = fetch_set_elements(tid, db, key) |> MapSet.new()
            MapSet.difference(acc, other_set)
          end)
      end

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

  # Private helpers

  @spec fetch_set_elements(:ets.table(), db(), key()) :: [any()]
  defp fetch_set_elements(table, db, key) do
    match_spec = [
      {{{db, key, :set, :"$1"}, :_}, [], [:"$1"]}
    ]

    :ets.select(table, match_spec)
  end
end
