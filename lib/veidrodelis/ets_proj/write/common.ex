defmodule Vdr.ETSProj.Write.Common do
  @moduledoc """
  Common write operations for ETS-backed stores.
  """

  @type db :: non_neg_integer()
  @type key :: any()

  @doc """
  Deletes a key from the store.
  Uses match_delete to remove all entries for the key regardless of type.
  """
  @spec del(:ets.tid(), db(), key()) :: :ok
  def del(tid, db, key) do
    :ets.match_delete(tid, {{db, key, :_, :_}, :_})
    :ok
  end
end
