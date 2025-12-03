defmodule Vdr.ETSProj.Read.Strings do
  @moduledoc """
  Read operations for Redis string store.

  Reads already-decoded data from ETS.
  """

  defstruct [:tid]

  @type t :: %__MODULE__{
          tid: :ets.tid()
        }

  @type db :: non_neg_integer()
  @type key :: any()
  @type value :: binary()

  @doc """
  Creates a new string read store with the given ETS table.
  """
  @spec new(:ets.tid()) :: t()
  def new(tid) do
    %__MODULE__{tid: tid}
  end

  @doc """
  Gets the original (binary) value for a key.
  Returns nil if the key doesn't exist.
  """
  @spec get(t(), db(), key()) :: value() | nil
  def get(%__MODULE__{tid: tid}, db, key) do
    case :ets.lookup(tid, {db, key, :string, nil}) do
      [] -> nil
      [{{^db, ^key, :string, nil}, {value, _decoded}}] -> value
    end
  end

  @doc """
  Gets the decoded value for a key.
  Returns nil if the key doesn't exist.
  """
  @spec get_decoded(t(), db(), key()) :: any()
  def get_decoded(%__MODULE__{tid: tid}, db, key) do
    case :ets.lookup(tid, {db, key, :string, nil}) do
      [] -> nil
      [{{^db, ^key, :string, nil}, {_value, decoded}}] -> decoded
    end
  end
end
