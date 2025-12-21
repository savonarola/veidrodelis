defmodule Vdr.MapProj.Common do
  @moduledoc """
  Common operations for MapProj stores.
  """

  @type db :: non_neg_integer()
  @type key :: any()
  @type store :: %{db() => %{key() => any()}}

  @doc """
  Deletes a key from the store.
  Returns the updated store.
  """
  @spec del(store(), db(), key()) :: store()
  def del(store, db, key) do
    case Map.get(store, db) do
      nil ->
        store

      db_map ->
        new_db_map = Map.delete(db_map, key)
        Map.put(store, db, new_db_map)
    end
  end
end
