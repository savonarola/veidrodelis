defmodule Vdr.MapProj.Hashes do
  @moduledoc """
  Hash store operations for MapProj.

  Stores hash values in a map structure using raw binaries.
  Each hash is stored as a map of binary field => binary value.
  """

  @type db :: non_neg_integer()
  @type key :: binary()
  @type field :: binary()
  @type value :: binary()
  @type store :: %{db() => %{key() => %{field() => value()}}}

  @doc """
  Sets one or more field-value pairs in a hash.
  Returns the updated store.
  """
  @spec hset(store(), db(), key(), [{field(), value()}]) :: store()
  def hset(store, db, key, field_values) when is_list(field_values) do
    db_map = Map.get(store, db, %{})

    entries =
      case Map.get(db_map, key) do
        nil -> %{}
        entries when is_map(entries) -> entries
      end

    new_entries =
      Enum.reduce(field_values, entries, fn {field, value}, acc ->
        Map.put(acc, field, value)
      end)

    new_db_map = Map.put(db_map, key, new_entries)
    Map.put(store, db, new_db_map)
  end

  @doc """
  Removes one or more fields from a hash.
  Returns the updated store.
  """
  @spec hdel(store(), db(), key(), [field()]) :: store()
  def hdel(store, db, key, fields) when is_list(fields) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        store

      entries when is_map(entries) ->
        new_entries =
          Enum.reduce(fields, entries, fn field, acc ->
            Map.delete(acc, field)
          end)

        store_entries(store, db, key, new_entries)
    end
  end

  @doc """
  Gets the value associated with a field in a hash.
  """
  @spec hget(store(), db(), key(), field()) :: value() | nil
  def hget(store, db, key, field) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        nil

      entries when is_map(entries) ->
        Map.get(entries, field)

      _ ->
        nil
    end
  end

  @doc """
  Checks if a field exists in a hash.
  """
  @spec hexists(store(), db(), key(), field()) :: boolean()
  def hexists(store, db, key, field) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil -> false
      entries when is_map(entries) -> Map.has_key?(entries, field)
      _ -> false
    end
  end

  @doc """
  Gets all field-value pairs from a hash.
  Returns a list of tuples {field, value}.
  """
  @spec hgetall(store(), db(), key()) :: [{field(), value()}]
  def hgetall(store, db, key) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        []

      entries when is_map(entries) ->
        Map.to_list(entries)

      _ ->
        []
    end
  end

  @doc """
  Gets all fields from a hash.
  Returns a list of binary fields.
  """
  @spec hkeys(store(), db(), key()) :: [field()]
  def hkeys(store, db, key) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil -> []
      entries when is_map(entries) -> Map.keys(entries)
      _ -> []
    end
  end

  @doc """
  Gets all values from a hash.
  Returns a list of binary values.
  """
  @spec hvals(store(), db(), key()) :: [value()]
  def hvals(store, db, key) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        []

      entries when is_map(entries) ->
        Map.values(entries)

      _ ->
        []
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
      entries when is_map(entries) -> map_size(entries)
      _ -> 0
    end
  end

  @doc """
  Creates a stream of hash entries matching the filter function.

  The filter function receives {field, value} and returns true/false.
  Returns matching entries as {{db, key, :hset, field}, value} for compatibility.
  """
  @spec select_stream(store(), db(), key(), ({field(), value()} -> boolean())) ::
          Enumerable.t()
  def select_stream(store, db, key, filter_fun) when is_function(filter_fun, 1) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        Stream.filter([], fn _ -> true end)

      entries when is_map(entries) ->
        entries
        |> Stream.filter(filter_fun)
        |> Stream.map(fn {field, value} ->
          {{db, key, :hset, field}, value}
        end)
    end
  end

  @doc """
  Creates a reverse stream of hash entries matching the filter function.

  The filter function receives {field, value} and returns true/false.
  Returns matching entries in reverse order as {{db, key, :hset, field}, value}.
  """
  @spec select_rev_stream(store(), db(), key(), ({field(), value()} -> boolean())) ::
          Enumerable.t()
  def select_rev_stream(store, db, key, filter_fun) when is_function(filter_fun, 1) do
    db_map = Map.get(store, db, %{})

    case Map.get(db_map, key) do
      nil ->
        Stream.filter([], fn _ -> true end)

      entries when is_map(entries) ->
        entries
        |> Enum.to_list()
        |> Enum.reverse()
        |> Stream.filter(filter_fun)
        |> Stream.map(fn {field, value} ->
          {{db, key, :hset, field}, value}
        end)
    end
  end

  # Private helpers

  @spec store_entries(store(), db(), key(), %{field() => value()}) :: store()
  defp store_entries(store, db, key, entries) do
    if map_size(entries) == 0 do
      # Remove the key when the hash is empty
      case Map.get(store, db) do
        nil ->
          store

        db_map ->
          new_db_map = Map.delete(db_map, key)
          Map.put(store, db, new_db_map)
      end
    else
      db_map = Map.get(store, db, %{})
      new_db_map = Map.put(db_map, key, entries)
      Map.put(store, db, new_db_map)
    end
  end
end
