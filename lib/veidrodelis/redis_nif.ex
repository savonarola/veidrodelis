defmodule Vdr.RedisNif do
  @moduledoc false

  use Rustler,
    otp_app: :veidrodelis,
    crate: :vdr_redis_nif,
    mode: if(Mix.env() == :prod, do: :release, else: :debug)

  # RDB Parser NIFs
  @doc false
  def rdb_create(), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def rdb_data(_parser, _chunk), do: :erlang.nif_error(:nif_not_loaded)

  # Replica Parser NIFs
  @doc false
  def replica_create(), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def replica_data(_parser, _chunk), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def replica_state(_parser), do: :erlang.nif_error(:nif_not_loaded)
end
