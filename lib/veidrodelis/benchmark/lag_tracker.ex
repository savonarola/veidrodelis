defmodule Vdr.Benchmark.LagTracker do
  @moduledoc """
  Tracks replication lag by monitoring timestamp markers in the data stream.
  """

  use GenServer

  defstruct [
    :vdr_id,
    :tracker_key,
    :lag_samples,
    :start_time,
    :last_timestamp,
    :redis_conn,
    :timestamp_interval_ms
  ]

  @doc """
  Starts a lag tracker that monitors a specific key for timestamp updates.

  The lag tracker automatically injects timestamp markers into Redis at the
  specified interval and monitors the replicated data stream to measure lag.

  Options:
    * `:vdr_id` - Veidrodelis instance ID
    * `:tracker_key` - Key to monitor for timestamps (default: "_ts")
    * `:redis_conn` - Redix connection PID for injecting timestamps
    * `:timestamp_interval_ms` - How often to inject timestamps (default: 500ms)
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets all collected lag samples.
  Returns a list of {timestamp_ms, lag_ms} tuples.
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

  @doc """
  Gets the latest lag measurement.
  Returns lag in milliseconds or nil if no samples yet.
  """
  def get_latest_lag do
    GenServer.call(__MODULE__, :get_latest_lag)
  end

  @impl true
  def init(opts) do
    vdr_id = Keyword.fetch!(opts, :vdr_id)
    tracker_key = Keyword.get(opts, :tracker_key, "_ts")
    redis_conn = Keyword.fetch!(opts, :redis_conn)
    timestamp_interval_ms = Keyword.get(opts, :timestamp_interval_ms, 500)

    state = %__MODULE__{
      vdr_id: vdr_id,
      tracker_key: tracker_key,
      lag_samples: [],
      start_time: System.monotonic_time(:millisecond),
      last_timestamp: nil,
      redis_conn: redis_conn,
      timestamp_interval_ms: timestamp_interval_ms
    }

    # Schedule both polling and timestamp injection
    schedule_poll()
    schedule_timestamp_injection()

    {:ok, state}
  end

  @impl true
  def handle_call(:get_lag_samples, _from, state) do
    {:reply, Enum.reverse(state.lag_samples), state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    new_state = %{
      state
      | lag_samples: [],
        start_time: System.monotonic_time(:millisecond),
        last_timestamp: nil
    }

    # Clear the timestamp key in Redis
    try do
      Redix.command!(state.redis_conn, ["DEL", state.tracker_key])
    rescue
      _ -> :ok
    end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_latest_lag, _from, state) do
    lag =
      case state.lag_samples do
        [] -> nil
        [latest | _] -> elem(latest, 1)
      end

    {:reply, lag, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = check_lag(state)
    schedule_poll()
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:inject_timestamp, state) do
    inject_timestamp(state)
    schedule_timestamp_injection(state.timestamp_interval_ms)
    {:noreply, state}
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, 100)
  end

  defp schedule_timestamp_injection(interval_ms \\ 500) do
    Process.send_after(self(), :inject_timestamp, interval_ms)
  end

  defp inject_timestamp(state) do
    timestamp_ms = System.system_time(:millisecond)

    try do
      # Inject timestamp marker: DEL _ts; LPUSH _ts <timestamp>
      Redix.command!(state.redis_conn, ["DEL", state.tracker_key])

      Redix.command!(state.redis_conn, [
        "LPUSH",
        state.tracker_key,
        Integer.to_string(timestamp_ms)
      ])
    rescue
      e ->
        IO.puts("Warning: Failed to inject timestamp: #{inspect(e)}")
    end
  end

  defp check_lag(state) do
    # NOTE: List support has been removed, so lag tracking is currently disabled
    # TODO: Implement lag tracking using string keys instead of lists
    state

    # try do
    #   # Get the list store and check for the tracker key
    #   list_store = Veidrodelis.lists(state.vdr_id)
    #
    #   # Check if the key exists and get its value (index 0)
    #   result = Vdr.ListStore.get_range(list_store, 0, state.tracker_key, 0, 0)
    #
    #   case result do
    #     [] ->
    #       # Key doesn't exist yet or list is empty
    #       state
    #
    #     [timestamp_value] ->
    #       # Convert to string if it's not already
    #       timestamp_str = to_string(timestamp_value)
    #
    #       # Parse timestamp from string
    #       case Integer.parse(timestamp_str) do
    #         {sent_time_ms, _} ->
    #           # Only record if this is a new timestamp
    #           if sent_time_ms != state.last_timestamp do
    #             current_time_ms = System.system_time(:millisecond)
    #             lag_ms = current_time_ms - sent_time_ms
    #             relative_time_ms = System.monotonic_time(:millisecond) - state.start_time
    #
    #             # Add sample (store most recent first)
    #             new_samples = [{relative_time_ms, lag_ms} | state.lag_samples]
    #             %{state | lag_samples: new_samples, last_timestamp: sent_time_ms}
    #           else
    #             # Same timestamp, don't record duplicate
    #             state
    #           end
    #
    #         :error ->
    #           # Failed to parse timestamp
    #           state
    #       end
    #
    #     _other ->
    #       # Unexpected result (list with more than one element)
    #       state
    #   end
    # rescue
    #   _e ->
    #     # Silently handle errors (e.g., store not yet initialized)
    #     state
    # end
  end
end
