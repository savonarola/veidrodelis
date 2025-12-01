defmodule Vdr.Benchmark.PassthroughDecoder do
  @moduledoc """
  Simple passthrough decoder that doesn't transform any data.
  Used for benchmarking to minimize decoder overhead.
  """
  @behaviour Veidrodelis

  # All decoder callbacks just pass through the raw binary values
  @impl true
  def decode_key(key), do: key

  @impl true
  def decode_string_value(_key, value), do: value

  @impl true
  def decode_set_entry(_key, entry), do: entry

  @impl true
  def decode_hash_hkey(_key, hkey), do: hkey

  @impl true
  def decode_hash_entry(_key, _hkey, value), do: value

  @impl true
  def decode_zset_entry(_key, entry), do: entry
end
