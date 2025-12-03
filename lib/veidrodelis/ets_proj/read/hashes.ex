defmodule Vdr.ETSProj.Read.Hashes do
  @moduledoc """
  Read operations for Redis hash store.

  Reads already-decoded data from ETS.
  """

  defstruct [:tid]

  @type t :: %__MODULE__{
          tid: :ets.tid()
        }

  @type db :: non_neg_integer()
  @type key :: any()
  @type hkey :: any()
  @type value :: binary()

  @doc """
  Creates a new hash read store with the given ETS table.
  """
  @spec new(:ets.tid()) :: t()
  def new(tid) do
    %__MODULE__{tid: tid}
  end

  @doc """
  Gets the decoded value associated with a field in a hash.
  Note: This requires the decoded hkey value.
  """
  @spec hget(t(), db(), key(), hkey()) :: any() | nil
  def hget(%__MODULE__{tid: tid}, db, key, decoded_hkey) do
    case :ets.lookup(tid, {db, key, :hset, decoded_hkey}) do
      [] -> nil
      [{_, {_orig_value, decoded_value}}] -> decoded_value
    end
  end

  @doc """
  Gets the original (binary) value associated with a field in a hash.
  Note: This requires the decoded hkey value.
  """
  @spec hget_original(t(), db(), key(), hkey()) :: value() | nil
  def hget_original(%__MODULE__{tid: tid}, db, key, decoded_hkey) do
    case :ets.lookup(tid, {db, key, :hset, decoded_hkey}) do
      [] -> nil
      [{_, {orig_value, _decoded_value}}] -> orig_value
    end
  end

  @doc """
  Checks if a field exists in a hash.
  Note: This requires the decoded hkey value.
  """
  @spec hexists(t(), db(), key(), hkey()) :: boolean()
  def hexists(%__MODULE__{tid: tid}, db, key, decoded_hkey) do
    case :ets.lookup(tid, {db, key, :hset, decoded_hkey}) do
      [] -> false
      [_] -> true
    end
  end

  @doc """
  Gets all field-value pairs from a hash.
  Returns a list of tuples `{decoded_hkey, decoded_value}`.
  """
  @spec hgetall(t(), db(), key()) :: [{hkey(), any()}]
  def hgetall(%__MODULE__{tid: tid}, db, key) do
    match_spec = [
      {{{db, key, :hset, :"$1"}, {:"$2", :"$3"}}, [], [{{:"$1", :"$3"}}]}
    ]

    :ets.select(tid, match_spec)
  end

  @doc """
  Gets all fields from a hash.
  Returns a list of decoded hkeys.
  """
  @spec hkeys(t(), db(), key()) :: [hkey()]
  def hkeys(%__MODULE__{tid: tid}, db, key) do
    match_spec = [
      {{{db, key, :hset, :"$1"}, :_}, [], [:"$1"]}
    ]

    :ets.select(tid, match_spec)
  end

  @doc """
  Gets all values from a hash.
  Returns a list of decoded values.
  """
  @spec hvals(t(), db(), key()) :: [any()]
  def hvals(%__MODULE__{tid: tid}, db, key) do
    match_spec = [
      {{{db, key, :hset, :_}, {:"$1", :"$2"}}, [], [:"$2"]}
    ]

    :ets.select(tid, match_spec)
  end

  @doc """
  Returns the number of fields in a hash.
  """
  @spec hlen(t(), db(), key()) :: non_neg_integer()
  def hlen(%__MODULE__{tid: tid}, db, key) do
    match_spec = [
      {{{db, key, :hset, :_}, :_}, [], [true]}
    ]

    :ets.select_count(tid, match_spec)
  end
end
