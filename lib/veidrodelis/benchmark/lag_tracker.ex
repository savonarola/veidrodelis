defmodule Vdr.Benchmark.LagTracker do
  @moduledoc false

  # Tracks replication lag by monitoring timestamp markers in the data stream.

  # Measures lag by:
  # 1. Pushing timestamps to Redis list key "lagmon" at regular intervals
  # 2. Monitoring replicated data to detect when these timestamps arrive
  # 3. Calculating lag as the difference between send and receive times

  use GenServer

  alias Vdr.RedisStream.CommandFilter

  require Logger

  defstruct [
    :vdr_id,
    :tracker_key,
    :start_time,
    :redis_conn,
    :timestamp_interval_ms
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def command_filter() do
    %CommandFilter{
      pre_handle: fn replica_command ->
        case replica_command.command do
          {:lpush, "lagmon", values} ->
            receive_time = integer_to_binary(System.system_time(:microsecond))

            modified_values =
              Enum.map(values, fn value -> <<value::binary, "-", receive_time::binary>> end)

            modified_command = {:lpush, "lagmon", modified_values}

            {:ok, %{replica_command | command: modified_command}}

          _other_command ->
            {:ok, replica_command}
        end
      end
    }
  end

  def get_lag_samples do
    GenServer.call(__MODULE__, :get_lag_samples)
  end

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl GenServer
  def init(opts) do
    vdr_id = Keyword.fetch!(opts, :vdr_id)
    Logger.metadata(vdr: vdr_id)
    tracker_key = Keyword.get(opts, :tracker_key, "lagmon")
    redis_conn = Keyword.fetch!(opts, :redis_conn)
    timestamp_interval_ms = Keyword.get(opts, :timestamp_interval_ms, 1000)

    state = %__MODULE__{
      vdr_id: vdr_id,
      tracker_key: tracker_key,
      start_time: System.monotonic_time(:microsecond),
      redis_conn: redis_conn,
      timestamp_interval_ms: timestamp_interval_ms
    }

    schedule_timestamp_injection()

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_lag_samples, _from, state) do
    samples = fetch_lag_samples(state)
    {:reply, samples, state}
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    new_state = %{
      state
      | start_time: System.monotonic_time(:microsecond)
    }

    Redix.command!(state.redis_conn, ["DEL", state.tracker_key])

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_info(:inject_timestamp, state) do
    inject_timestamp(state)
    schedule_timestamp_injection(state.timestamp_interval_ms)
    {:noreply, state}
  end

  defp schedule_timestamp_injection(interval_ms \\ 500) do
    Process.send_after(self(), :inject_timestamp, interval_ms)
  end

  defp inject_timestamp(state) do
    timestamp_us = System.system_time(:microsecond)

    try do
      res =
        Redix.command!(state.redis_conn, [
          "LPUSH",
          state.tracker_key,
          Integer.to_string(timestamp_us)
        ])

      Logger.debug("inject_timestamp LPUSH result: #{inspect(res)}")
    rescue
      e ->
        Logger.warning("Failed to inject timestamp: #{inspect(e)}")
    end
  end

  defp fetch_lag_samples(state) do
    try do
      {:ok, entries} = Veidrodelis.lrange(state.vdr_id, 0, state.tracker_key, 0, -1)
      Logger.debug("fetch_lag_samples entries: #{inspect(entries)}")

      case entries do
        [] ->
          []

        binary_entries ->
          parsed_entries =
            binary_entries
            |> Enum.map(&parse_lag_entry/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.reverse()

          case parsed_entries do
            [] ->
              []

            [{_, start_time} | _] = decoded_entries ->
              decoded_entries
              |> Enum.map(fn {received_ts_system, sent_ts_system} ->
                lag_us = received_ts_system - sent_ts_system
                {sent_ts_system - start_time, lag_us}
              end)
          end
      end
    rescue
      _e ->
        []
    end
  end

  # Parse a lag entry in format "sent_timestamp-receive_timestamp"
  defp parse_lag_entry(binary) when is_binary(binary) do
    case String.split(binary, "-", parts: 2) do
      [sent_str, received_str] ->
        {String.to_integer(received_str), String.to_integer(sent_str)}

      _ ->
        nil
    end
  end

  defp parse_lag_entry(_), do: nil

  defp integer_to_binary(int) when is_integer(int) do
    Integer.to_string(int)
  end
end
