defmodule Vdr.LZF do
  @moduledoc """
  LZF compression and decompression using a NIF (Native Implemented Function).

  LZF is a fast compression algorithm used by Redis for compressing data in RDB files.
  This module provides a native implementation via Rustler NIFs for maximum performance.
  """

  use Rustler,
    otp_app: :veidrodelis,
    crate: :vdr_nif,
    mode: if(Mix.env() == :prod, do: :release, else: :debug)

  @doc """
  Compress binary data using the LZF algorithm.

  ## Parameters

    * `data` - Binary data to compress

  ## Returns

    * `{:ok, compressed_binary}` - Successfully compressed
    * `{:error, reason}` - Compression failed

  ## Example

      iex> {:ok, compressed} = Vdr.LZF.compress("hello world")
      {:ok, <<...>>}
  """
  @spec compress(binary()) :: {:ok, binary()} | {:error, term()}
  def compress(_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Decompress LZF-compressed binary data.

  ## Parameters

    * `compressed_data` - Binary data compressed with LZF
    * `uncompressed_size` - Expected size of decompressed data

  ## Returns

    * `{:ok, decompressed_binary}` - Successfully decompressed
    * `{:error, reason}` - Decompression failed

  ## Example

      iex> {:ok, compressed} = Vdr.LZF.compress("hello world")
      iex> {:ok, decompressed} = Vdr.LZF.decompress(compressed, 11)
      {:ok, "hello world"}
  """
  @spec decompress(binary(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def decompress(_compressed_data, _uncompressed_size), do: :erlang.nif_error(:nif_not_loaded)
end
