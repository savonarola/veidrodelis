defmodule Vdr.Benchmark.LagTracker do
  @moduledoc """
  Tracks replication lag by monitoring timestamp markers in the data stream.

  Measures lag by:
  1. Pushing timestamps to Redis list key "lagmon" at regular intervals
  2. Monitoring replicated data to detect when these timestamps arrive
  3. Calculating lag as the difference between send and receive times
  """

  use GenServer

  require Logger

  defstruct [
    :vdr_id,
    :tracker_key,
    :start_time,
    :redis_conn,
    :timestamp_interval_ms
  ]

  @doc """
  Starts a lag tracker that monitors a specific key for timestamp updates.

  The lag tracker automatically injects timestamp markers into Redis at the
  specified interval and monitors the replicated data stream to measure lag.

  Options:
    * `:vdr_id` - Veidrodelis instance ID
    * `:tracker_key` - Key to monitor for timestamps (default: "lagmon")
    * `:redis_conn` - Redix connection PID for injecting timestamps
    * `:timestamp_interval_ms` - How often to inject timestamps (default: 1000ms)
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets all collected lag samples.
  Returns a list of {relative_time_ms, lag_ms} tuples.
  """
  def get_lag_samples do
    GenServer.call(__MODULE__, :get_lag_samples)
  end

  @doc """
  Clears all collected lag samples.
  """
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(opts) do
    vdr_id = Keyword.fetch!(opts, :vdr_id)
    tracker_key = Keyword.get(opts, :tracker_key, "lagmon")
    redis_conn = Keyword.fetch!(opts, :redis_conn)
    timestamp_interval_ms = Keyword.get(opts, :timestamp_interval_ms, 1000)

    state = %__MODULE__{
      vdr_id: vdr_id,
      tracker_key: tracker_key,
      start_time: System.monotonic_time(:millisecond),
      redis_conn: redis_conn,
      timestamp_interval_ms: timestamp_interval_ms
    }

    # Schedule timestamp injection
    schedule_timestamp_injection()

    {:ok, state}
  end

  @impl true
  def handle_call(:get_lag_samples, _from, state) do
    samples = fetch_lag_samples(state)
    {:reply, samples, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    new_state = %{
      state
      | start_time: System.monotonic_time(:millisecond)
    }

    # Clear the timestamp key in Redis
    Redix.command!(state.redis_conn, ["DEL", state.tracker_key])

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:inject_timestamp, state) do
    inject_timestamp(state)
    schedule_timestamp_injection(state.timestamp_interval_ms)
    {:noreply, state}
  end

  defp schedule_timestamp_injection(interval_ms \\ 500) do
    Process.send_after(self(), :inject_timestamp, interval_ms)
  end

  defp inject_timestamp(state) do
    # Use system_time (wall clock) for measuring actual lag
    timestamp_ms = System.system_time(:millisecond)

    try do
      # Push timestamp to lagmon list
      res = Redix.command!(state.redis_conn, [
        "LPUSH",
        state.tracker_key,
        Integer.to_string(timestamp_ms)
      ])
      Logger.debug("inject_timestamp LPUSH result: #{inspect(res)}")
    rescue
      e ->
        Logger.warning("Failed to inject timestamp: #{inspect(e)}")
    end
  end

  defp fetch_lag_samples(state) do
    try do
      # Get the list store and read all lagmon entries
      list_store = Veidrodelis.lists(state.vdr_id)

      # Get all entries from the lagmon list (db 0)
      # Use lrange to get all elements (0 to -1 means all)
      entries = Vdr.ListStore.lrange(list_store, 0, state.tracker_key, 0, -1)
      Logger.debug("fetch_lag_samples entries: #{inspect(entries)}")

      case entries do
        [] ->
          # No entries yet
          []

        decoded_entries ->
          decoded_entries = Enum.reverse(decoded_entries)
          [{_, start_time} | _] = decoded_entries
          decoded_entries
          |> Enum.map(fn {received_ts_system, sent_ts_system} ->
            lag_ms = received_ts_system - sent_ts_system
            {sent_ts_system - start_time, lag_ms}
          end)
      end
    rescue
      _e ->
        # Silently handle errors (e.g., store not yet initialized)
        []
    end
  end
end
