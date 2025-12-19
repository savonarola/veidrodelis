defmodule Vdr.RedisParser do
  @moduledoc false

  use Rustler,
    otp_app: :veidrodelis,
    crate: :vdr_nif,
    mode: if(Mix.env() == :prod, do: :release, else: :debug)

  # Internal LZF compression/decompression (used by Rust, not exposed to Elixir)
  @doc false
  def compress(_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def decompress(_compressed_data, _uncompressed_size), do: :erlang.nif_error(:nif_not_loaded)

  # RDB Parser NIFs
  @doc false
  def create(), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def data(_parser, _chunk), do: :erlang.nif_error(:nif_not_loaded)

  # Replica Parser NIFs
  @doc false
  def replica_create(), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def replica_data(_parser, _chunk), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def replica_state(_parser), do: :erlang.nif_error(:nif_not_loaded)
end
