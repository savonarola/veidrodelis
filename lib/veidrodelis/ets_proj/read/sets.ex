defmodule Vdr.ETSProj.Read.Sets do
  @moduledoc """
  Read operations for Redis set store.

  Reads already-decoded data from ETS.
  """

  defstruct [:tid]

  @type t :: %__MODULE__{
          tid: :ets.tid()
        }

  @type db :: non_neg_integer()
  @type key :: any()

  @doc """
  Creates a new set read store with the given ETS table.
  """
  @spec new(:ets.tid()) :: t()
  def new(tid) do
    %__MODULE__{tid: tid}
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
  Note: This requires the decoded member value.
  """
  @spec sismember(t(), db(), key(), any()) :: boolean()
  def sismember(%__MODULE__{tid: tid}, db, key, decoded_member) do
    case :ets.lookup(tid, {db, key, :set, decoded_member}) do
      [] -> false
      [_] -> true
    end
  end

  @doc """
  Returns the number of members in a set.
  """
  @spec scard(t(), db(), key()) :: non_neg_integer()
  def scard(%__MODULE__{tid: tid}, db, key) do
    match_spec = [
      {{{db, key, :set, :_}, :_}, [], [true]}
    ]

    :ets.select_count(tid, match_spec)
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
