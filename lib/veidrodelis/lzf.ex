defmodule Vdr.LZF do
  @moduledoc """
  LZF compression and decompression using a NIF (Native Implemented Function).

  LZF is a fast compression algorithm used by Redis for compressing data in RDB files.
  This module provides a native implementation via NIFs for maximum performance.
  """

  @on_load :init

  @doc false
  def init do
    so_name =
      case :code.priv_dir(:veidrodelis) do
        {:error, :bad_name} ->
          case :filelib.is_dir(:filename.join([~c"..", ~c"priv"])) do
            true ->
              :filename.join([~c"..", ~c"priv", ~c"vdr_lzf_nif"])

            _ ->
              :filename.join([~c"priv", ~c"vdr_lzf_nif"])
          end

        dir ->
          :filename.join(dir, ~c"vdr_lzf_nif")
      end

    :erlang.load_nif(so_name, 0)
  end

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
  def compress(data) when is_binary(data) do
    :erlang.nif_error({:not_loaded, [{:module, __MODULE__}, {:line, __ENV__.line}]})
  end

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
  def decompress(compressed_data, uncompressed_size)
      when is_binary(compressed_data) and is_integer(uncompressed_size) and uncompressed_size >= 0 do
    :erlang.nif_error({:not_loaded, [{:module, __MODULE__}, {:line, __ENV__.line}]})
  end
end
