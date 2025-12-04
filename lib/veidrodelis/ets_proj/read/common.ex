defmodule Vdr.ETSProj.Read.Common do
  @moduledoc """
  Common read operations for ETS-backed stores.
  """

  alias VDR.ETSRead

  @type db :: non_neg_integer()
  @type key :: any()
  @type key_type :: :string | :hset | :set | :list | :zset

  @doc """
  Creates a stream of {key, type} tuples for all keys in the database.

  Iterates through all entries in forward order and yields unique {key, type} tuples.
  Skips :zset_index entries which are internal indexes for sorted sets.

  Returns tuples where type is one of: :string, :hset, :set, :list, :zset

  ## Parameters

    * `tid` - The ETS table identifier
    * `db` - The database number

  ## Returns

  A `Stream.t()` that yields {key, type} tuples in forward order.
  """
  @spec key_stream(:ets.tid(), db()) :: Enumerable.t()
  def key_stream(tid, db) do
    # Match spec to extract {key, type} from all entries, skipping :zset_index
    # Pattern: {{db, key, type, _}, _}
    # Guard: type != :zset_index
    # Return: {key, type}
    match_spec = [
      {{{db, :"$1", :"$2", :_}, :_}, [{:"/=", :"$2", :zset_index}], [{{:"$1", :"$2"}}]}
    ]

    tid
    |> ETSRead.select_stream(match_spec, 100)
    |> Stream.dedup()
  end

  @doc """
  Creates a stream of {key, type} tuples for all keys in the database in reverse order.

  Iterates through all entries in reverse order and yields unique {key, type} tuples.
  Skips :zset_index entries which are internal indexes for sorted sets.

  Returns tuples where type is one of: :string, :hset, :set, :list, :zset

  ## Parameters

    * `tid` - The ETS table identifier
    * `db` - The database number

  ## Returns

  A `Stream.t()` that yields {key, type} tuples in reverse order.
  """
  @spec key_rev_stream(:ets.tid(), db()) :: Enumerable.t()
  def key_rev_stream(tid, db) do
    # Match spec to extract {key, type} from all entries, skipping :zset_index
    # Pattern: {{db, key, type, _}, _}
    # Guard: type != :zset_index
    # Return: {key, type}
    match_spec = [
      {{{db, :"$1", :"$2", :_}, :_}, [{:"/=", :"$2", :zset_index}], [{{:"$1", :"$2"}}]}
    ]

    tid
    |> ETSRead.select_rev_stream(match_spec, 100)
    |> Stream.dedup()
  end
end
