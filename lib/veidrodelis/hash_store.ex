defmodule Veidrodelis.HashStore do
  @moduledoc """
  An ETS-backed store for Redis hash operations.

  Uses a protected named ETS table to store hash fields with decoded keys and values.
  Each entry is stored as `{{db, key, decoded_hkey}, decoded_value}`.

  The decode_hkey function is called for each field to compute a decoded representation
  that is stored in the ETS key for efficient matching and ordering.
  The decode function is called for each value to compute a decoded representation
  that is stored as the ETS value.
  """

  defstruct [:table, :decode_hkey_fun, :decode_fun]

  @type t :: %__MODULE__{
          table: atom(),
          decode_hkey_fun: decode_hkey_fun(),
          decode_fun: decode_fun()
        }

  @type db :: non_neg_integer()
  @type key :: any()
  @type hkey :: any()
  @type field :: binary()
  @type value :: binary()
  @type entry :: any()
  @type decode_hkey_fun :: (key(), field() -> hkey())
  @type decode_fun :: (key(), hkey(), value() -> entry())

  @doc """
  Creates a new hash store with the given name and decode functions.

  The decode_hkey function receives `(key, field)` and returns a decoded hkey
  that will be used as part of the ETS key for efficient matching and ordering.

  The decode function receives `(key, hkey, value)` and returns a decoded entry
  that will be stored as the ETS value.

  Returns a HashStore struct containing the table name and decode functions.
  """
  @spec new(atom(), decode_hkey_fun(), decode_fun()) :: t()
  def new(name, decode_hkey_fun, decode_fun)
      when is_atom(name) and is_function(decode_hkey_fun, 2) and is_function(decode_fun, 3) do
    :ets.new(name, [:ordered_set, :protected, :named_table])
    %__MODULE__{table: name, decode_hkey_fun: decode_hkey_fun, decode_fun: decode_fun}
  end

  @doc """
  Sets one or more field-value pairs in a hash.

  HSET key field value [field value ...]
  """
  @spec hset(t(), db(), key(), [{field(), value()}]) :: :ok
  def hset(
        %__MODULE__{table: table, decode_hkey_fun: decode_hkey_fun, decode_fun: decode_fun},
        db,
        key,
        field_values
      )
      when is_list(field_values) do
    entries =
      Enum.map(field_values, fn {field, value} ->
        decoded_hkey = decode_hkey_fun.(key, field)
        decoded_value = decode_fun.(key, decoded_hkey, value)
        {{db, key, decoded_hkey}, decoded_value}
      end)

    :ets.insert(table, entries)
    :ok
  end

  @doc """
  Removes one or more fields from a hash.

  HDEL key field [field ...]
  """
  @spec hdel(t(), db(), key(), [field()]) :: :ok
  def hdel(%__MODULE__{table: table, decode_hkey_fun: decode_hkey_fun}, db, key, fields)
      when is_list(fields) do
    Enum.each(fields, fn field ->
      decoded_hkey = decode_hkey_fun.(key, field)
      :ets.delete(table, {db, key, decoded_hkey})
    end)

    :ok
  end

  @doc """
  Gets the value associated with a field in a hash.

  HGET key field

  Returns the decoded value if the field exists, or nil if it doesn't.
  """
  @spec hget(t(), db(), key(), field()) :: entry() | nil
  def hget(%__MODULE__{table: table, decode_hkey_fun: decode_hkey_fun}, db, key, field) do
    decoded_hkey = decode_hkey_fun.(key, field)

    case :ets.lookup(table, {db, key, decoded_hkey}) do
      [] -> nil
      [{_, decoded_value}] -> decoded_value
    end
  end

  @doc """
  Checks if a field exists in a hash.

  HEXISTS key field
  """
  @spec hexists(t(), db(), key(), field()) :: boolean()
  def hexists(%__MODULE__{table: table, decode_hkey_fun: decode_hkey_fun}, db, key, field) do
    decoded_hkey = decode_hkey_fun.(key, field)

    case :ets.lookup(table, {db, key, decoded_hkey}) do
      [] -> false
      [_] -> true
    end
  end

  @doc """
  Gets all field-value pairs from a hash.

  HGETALL key

  Returns a list of tuples `{decoded_hkey, decoded_value}`.
  """
  @spec hgetall(t(), db(), key()) :: [{hkey(), entry()}]
  def hgetall(%__MODULE__{table: table}, db, key) do
    # Use matchspec to fetch all fields and values
    match_spec = [
      {{{db, key, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}
    ]

    :ets.select(table, match_spec)
  end

  @doc """
  Gets all fields from a hash.

  HKEYS key

  Returns a list of decoded hkeys.
  """
  @spec hkeys(t(), db(), key()) :: [hkey()]
  def hkeys(%__MODULE__{table: table}, db, key) do
    # Use matchspec to fetch only fields
    match_spec = [
      {{{db, key, :"$1"}, :_}, [], [:"$1"]}
    ]

    :ets.select(table, match_spec)
  end

  @doc """
  Gets all values from a hash.

  HVALS key

  Returns a list of decoded values.
  """
  @spec hvals(t(), db(), key()) :: [entry()]
  def hvals(%__MODULE__{table: table}, db, key) do
    # Use matchspec to fetch only values
    match_spec = [
      {{{db, key, :_}, :"$1"}, [], [:"$1"]}
    ]

    :ets.select(table, match_spec)
  end

  @doc """
  Returns the number of fields in a hash.

  HLEN key
  """
  @spec hlen(t(), db(), key()) :: non_neg_integer()
  def hlen(%__MODULE__{table: table}, db, key) do
    # Use matchspec to count efficiently
    match_spec = [
      {{{db, key, :_}, :_}, [], [true]}
    ]

    :ets.select_count(table, match_spec)
  end

  @doc """
  Deletes an entire hash.

  DEL key
  """
  @spec del(t(), db(), key()) :: :ok
  def del(%__MODULE__{table: table}, db, key) do
    clear_hash(table, db, key)
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

  # Clears all fields from a hash
  @spec clear_hash(:ets.table(), db(), key()) :: :ok
  defp clear_hash(table, db, key) do
    # Use matchspec to efficiently delete all entries with bounded {db, key, ...}
    match_spec = [
      {{{db, key, :_}, :_}, [], [true]}
    ]

    :ets.select_delete(table, match_spec)
    :ok
  end
end

