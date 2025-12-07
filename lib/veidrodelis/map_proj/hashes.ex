defmodule Vdr.MapProj.Hashes do
  @moduledoc """
  Hash store operations for MapProj.

  Stores hash values in a map structure.
  Each hash is stored as `%Hash{entries: %{hkey => {raw, decoded}}}`.
  """

  defmodule Hash do
    @moduledoc false
    defstruct [:entries]

    @type entry :: {raw :: binary(), decoded :: any()}

    @type t :: %__MODULE__{
            entries: %{any() => entry()}
          }
  end

  defstruct [:decode_hkey_fun, :decode_fun]

  @type t :: %__MODULE__{
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
  @type store :: %{db() => %{key() => Hash.t()}}

  @doc """
  Creates a new hash store configuration with the given decode functions.
  """
  @spec new(decode_hkey_fun(), decode_fun()) :: t()
  def new(decode_hkey_fun, decode_fun)
      when is_function(decode_hkey_fun, 2) and is_function(decode_fun, 3) do
    %__MODULE__{decode_hkey_fun: decode_hkey_fun, decode_fun: decode_fun}
  end

  @doc """
  Sets one or more field-value pairs in a hash.
  Returns the updated store.
  """
  @spec hset(store(), t(), db(), key(), [{field(), value()}]) :: store()
  def hset(
        store,
        %__MODULE__{decode_hkey_fun: decode_hkey_fun, decode_fun: decode_fun},
        db,
        key,
        field_values
      )
      when is_list(field_values) do
    db_map = Map.get(store, db, %{})

    entries =
      case Map.get(db_map, key) do
        nil -> %{}
        %Hash{entries: e} -> e
      end

    new_entries =
      Enum.reduce(field_values, entries, fn {field, value}, acc ->
        decoded_hkey = decode_hkey_fun.(key, field)
        decoded_value = decode_fun.(key, decoded_hkey, value)
        Map.put(acc, decoded_hkey, {value, decoded_value})
      end)

    hash_entry = %Hash{entries: new_entries}
    new_db_map = Map.put(db_map, key, hash_entry)
    Map.put(store, db, new_db_map)
  end

  @doc """
  Removes one or more fields from a hash.
  Returns the updated store.
  """
  @spec hdel(store(), t(), db(), key(), [field()]) :: store()
  def hdel(store, %__MODULE__{decode_hkey_fun: decode_hkey_fun}, db, key, fields)
      when is_list(fields) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        store

      %Hash{entries: entries} ->
        new_entries =
          Enum.reduce(fields, entries, fn field, acc ->
            decoded_hkey = decode_hkey_fun.(key, field)
            Map.delete(acc, decoded_hkey)
          end)

        store_entries(store, db, key, new_entries)
    end
  end

  @doc """
  Gets the decoded value associated with a field in a hash.
  Note: This requires the decoded hkey value.
  """
  @spec hget(store(), db(), key(), hkey()) :: any() | nil
  def hget(store, db, key, decoded_hkey) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil -> nil
      %Hash{entries: entries} ->
        case Map.get(entries, decoded_hkey) do
          nil -> nil
          {_raw, decoded} -> decoded
        end
      _ -> nil
    end
  end

  @doc """
  Gets the original (binary) value associated with a field in a hash.
  Note: This requires the decoded hkey value.
  """
  @spec hget_original(store(), db(), key(), hkey()) :: value() | nil
  def hget_original(store, db, key, decoded_hkey) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil -> nil
      %Hash{entries: entries} ->
        case Map.get(entries, decoded_hkey) do
          nil -> nil
          {raw, _decoded} -> raw
        end
      _ -> nil
    end
  end

  @doc """
  Checks if a field exists in a hash.
  Note: This requires the decoded hkey value.
  """
  @spec hexists(store(), db(), key(), hkey()) :: boolean()
  def hexists(store, db, key, decoded_hkey) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil -> false
      %Hash{entries: entries} -> Map.has_key?(entries, decoded_hkey)
      _ -> false
    end
  end

  @doc """
  Gets all field-value pairs from a hash.
  Returns a list of tuples `{decoded_hkey, decoded_value}`.
  """
  @spec hgetall(store(), db(), key()) :: [{hkey(), any()}]
  def hgetall(store, db, key) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil -> []
      %Hash{entries: entries} ->
        Enum.map(entries, fn {hkey, {_raw, decoded}} ->
          {hkey, decoded}
        end)
      _ -> []
    end
  end

  @doc """
  Gets all fields from a hash.
  Returns a list of decoded hkeys.
  """
  @spec hkeys(store(), db(), key()) :: [hkey()]
  def hkeys(store, db, key) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil -> []
      %Hash{entries: entries} -> Map.keys(entries)
      _ -> []
    end
  end

  @doc """
  Gets all values from a hash.
  Returns a list of decoded values.
  """
  @spec hvals(store(), db(), key()) :: [any()]
  def hvals(store, db, key) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil -> []
      %Hash{entries: entries} ->
        Enum.map(entries, fn {_hkey, {_raw, decoded}} -> decoded end)
      _ -> []
    end
  end

  @doc """
  Returns the number of fields in a hash.
  """
  @spec hlen(store(), db(), key()) :: non_neg_integer()
  def hlen(store, db, key) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil -> 0
      %Hash{entries: entries} -> map_size(entries)
      _ -> 0
    end
  end

  @doc """
  Creates a stream of hash entries matching the filter function.

  The filter function receives `{hkey, {raw, decoded}}` and returns true/false.
  Returns matching entries as `{{db, key, :hset, hkey}, {raw, decoded}}` for compatibility.
  """
  @spec select_stream(store(), db(), key(), ({hkey(), {binary(), any()}} -> boolean())) :: Enumerable.t()
  def select_stream(store, db, key, filter_fun) when is_function(filter_fun, 1) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        Stream.filter([], fn _ -> true end)

      %Hash{entries: entries} ->
        entries
        |> Stream.filter(filter_fun)
        |> Stream.map(fn {hkey, {raw, decoded}} ->
          {{db, key, :hset, hkey}, {raw, decoded}}
        end)
    end
  end

  @doc """
  Creates a reverse stream of hash entries matching the filter function.

  The filter function receives `{hkey, {raw, decoded}}` and returns true/false.
  Returns matching entries in reverse order as `{{db, key, :hset, hkey}, {raw, decoded}}`.
  """
  @spec select_rev_stream(store(), db(), key(), ({hkey(), {binary(), any()}} -> boolean())) :: Enumerable.t()
  def select_rev_stream(store, db, key, filter_fun) when is_function(filter_fun, 1) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        Stream.filter([], fn _ -> true end)

      %Hash{entries: entries} ->
        entries
        |> Enum.to_list()
        |> Enum.reverse()
        |> Stream.filter(filter_fun)
        |> Stream.map(fn {hkey, {raw, decoded}} ->
          {{db, key, :hset, hkey}, {raw, decoded}}
        end)
    end
  end

  # Private helpers

  @spec store_entries(store(), db(), key(), %{hkey() => {binary(), any()}}) :: store()
  defp store_entries(store, db, key, entries) do
    if map_size(entries) == 0 do
      # Remove the key when the hash is empty
      case Map.get(store, db) do
        nil -> store
        db_map ->
          new_db_map = Map.delete(db_map, key)
          Map.put(store, db, new_db_map)
      end
    else
      db_map = Map.get(store, db, %{})
      hash_entry = %Hash{entries: entries}
      new_db_map = Map.put(db_map, key, hash_entry)
      Map.put(store, db, new_db_map)
    end
  end
end
