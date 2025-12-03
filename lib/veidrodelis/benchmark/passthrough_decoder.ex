defmodule Vdr.Benchmark.PassthroughDecoder do
  @moduledoc """
  Simple passthrough decoder that doesn't transform any data.
  Used for benchmarking to minimize decoder overhead.

  Special handling for 'lagmon' key: list entries are decoded as
  {received_timestamp, sent_timestamp} tuples for lag measurement.
  """
  @behaviour Veidrodelis

  require Logger

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

  @impl true
  def decode_list_entry("lagmon", entry) do
    Logger.debug("decode_list_entry lagmon: #{inspect(entry)}")
    # For lagmon key, decode as {received_timestamp, sent_timestamp}
    received_ts = System.system_time(:millisecond)
    sent_ts = String.to_integer(entry)
    {received_ts, sent_ts}
  end

  def decode_list_entry(key, entry) do
    Logger.debug("decode_list_entry #{inspect(key)}: #{inspect(entry)}")
    entry
  end
end
