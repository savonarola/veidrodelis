defmodule Vdr.ETSProj.Write.Hashes do
  @moduledoc """
  Write operations for Redis hash store.

  Uses a shared ETS table to store hash fields with decoded keys and values.
  Each entry is stored as `{{db, decoded_key, :hset, decoded_hkey}, {original_hvalue, decoded_hvalue}}`.
  """

  defstruct [:tid, :decode_hkey_fun, :decode_fun]

  @type t :: %__MODULE__{
          tid: :ets.tid(),
          decode_hkey_fun: decode_hkey_fun(),
          decode_fun: decode_fun()
        }

  @type db :: non_neg_integer()
  @type key :: any()
  @type hkey :: any()
  @type field :: binary()
  @type value :: binary()
  @type decode_hkey_fun :: (key(), field() -> hkey())
  @type decode_fun :: (key(), hkey(), value() -> any())

  @doc """
  Creates a new hash store with the given ETS table and decode functions.
  """
  @spec new(:ets.tid(), decode_hkey_fun(), decode_fun()) :: t()
  def new(tid, decode_hkey_fun, decode_fun)
      when is_function(decode_hkey_fun, 2) and is_function(decode_fun, 3) do
    %__MODULE__{tid: tid, decode_hkey_fun: decode_hkey_fun, decode_fun: decode_fun}
  end

  @doc """
  Sets one or more field-value pairs in a hash.
  """
  @spec hset(t(), db(), key(), [{field(), value()}]) :: :ok
  def hset(
        %__MODULE__{tid: tid, decode_hkey_fun: decode_hkey_fun, decode_fun: decode_fun},
        db,
        key,
        field_values
      )
      when is_list(field_values) do
    entries =
      Enum.map(field_values, fn {field, value} ->
        decoded_hkey = decode_hkey_fun.(key, field)
        decoded_value = decode_fun.(key, decoded_hkey, value)
        {{db, key, :hset, decoded_hkey}, {value, decoded_value}}
      end)

    :ets.insert(tid, entries)
    :ok
  end

  @doc """
  Removes one or more fields from a hash.
  """
  @spec hdel(t(), db(), key(), [field()]) :: :ok
  def hdel(%__MODULE__{tid: tid, decode_hkey_fun: decode_hkey_fun}, db, key, fields)
      when is_list(fields) do
    Enum.each(fields, fn field ->
      decoded_hkey = decode_hkey_fun.(key, field)
      :ets.delete(tid, {db, key, :hset, decoded_hkey})
    end)

    :ok
  end
end
