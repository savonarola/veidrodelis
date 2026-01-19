defmodule Vdr.Benchmark.Reader do
  @moduledoc """
  Spawns reader processes that hammer Veidrodelis with read commands in a hot loop.

  Each reader runs batches of read operations, recording average latency and hit rate
  per batch. Supports any read operation via the configurable `read_fn`.

  Collects latency samples and calculates TPS metrics.
  """

  use GenServer

  require Logger

  defstruct [
    :vdr_id,
    :reader_count,
    :read_fn,
    :reader_pids,
    :running,
    :samples_ets,
    :start_time,
    :total_ops,
    :batch_size
  ]

  # Number of operations per batch before recording a sample
  @default_batch_size 1000

  @doc """
  Starts the reader coordinator.

  Options:
    * `:vdr_id` - Veidrodelis instance ID (required)
    * `:reader_count` - Number of parallel reader processes (default: 4)
    * `:read_fn` - Function that returns `{read_operation, hit_check}` (required)
      - Direct: `{fn vdr_id -> Veidrodelis.get(vdr_id, 0, "key") end, fn result -> result != nil end}`
      - Transaction: `{fn vdr_id -> Veidrodelis.read_tx(vdr_id, 0, "return ts.get('key')") end, fn r -> r != nil end}`
    * `:batch_size` - Operations per batch before recording a sample (default: 1000)
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts all reader processes. They will run until `stop/0` is called.
  """
  def start_readers do
    GenServer.call(__MODULE__, :start_readers)
  end

  @doc """
  Stops all reader processes and returns collected metrics.

  Returns:
    %{
      total_ops: integer,
      duration_us: integer,
      tps: float,
      latency_samples: [{time_us, avg_latency_us, hit_rate}],
      total_hits: integer,
      total_misses: integer
    }
  """
  def stop_readers do
    GenServer.call(__MODULE__, :stop_readers, :infinity)
  end

  @doc """
  Gets current metrics without stopping readers.
  """
  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  @impl true
  def init(opts) do
    vdr_id = Keyword.fetch!(opts, :vdr_id)
    reader_count = Keyword.get(opts, :reader_count, 4)
    read_fn = Keyword.fetch!(opts, :read_fn)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    # Create ETS table for collecting samples from reader processes
    samples_ets = :ets.new(:reader_samples, [:public, :bag, {:write_concurrency, true}])

    state = %__MODULE__{
      vdr_id: vdr_id,
      reader_count: reader_count,
      read_fn: read_fn,
      reader_pids: [],
      running: false,
      samples_ets: samples_ets,
      start_time: nil,
      total_ops: :counters.new(1, [:atomics]),
      batch_size: batch_size
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:start_readers, _from, state) do
    if state.running do
      {:reply, {:error, :already_running}, state}
    else
      # Clear previous samples
      :ets.delete_all_objects(state.samples_ets)
      :counters.put(state.total_ops, 1, 0)

      start_time = System.monotonic_time(:microsecond)

      # Spawn reader processes
      reader_pids =
        for i <- 1..state.reader_count do
          spawn_reader(i, state, start_time)
        end

      new_state = %{state | reader_pids: reader_pids, running: true, start_time: start_time}
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:stop_readers, _from, state) do
    if not state.running do
      {:reply, {:error, :not_running}, state}
    else
      end_time = System.monotonic_time(:microsecond)

      # Signal all readers to stop
      Enum.each(state.reader_pids, fn pid ->
        send(pid, :stop)
      end)

      # Wait for readers to finish (with timeout)
      Enum.each(state.reader_pids, fn pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5000 ->
            Process.exit(pid, :kill)
            Process.demonitor(ref, [:flush])
        end
      end)

      # Collect metrics
      metrics = collect_metrics(state, end_time)

      new_state = %{state | reader_pids: [], running: false}
      {:reply, metrics, new_state}
    end
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    if state.running do
      end_time = System.monotonic_time(:microsecond)
      metrics = collect_metrics(state, end_time)
      {:reply, metrics, state}
    else
      {:reply, {:error, :not_running}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Cleanup ETS table
    if state.samples_ets do
      :ets.delete(state.samples_ets)
    end

    :ok
  end

  # Spawns a reader process that runs in a hot loop
  defp spawn_reader(reader_id, state, start_time) do
    vdr_id = state.vdr_id
    read_fn = state.read_fn
    samples_ets = state.samples_ets
    total_ops = state.total_ops
    batch_size = state.batch_size

    spawn_link(fn ->
      reader_loop(reader_id, vdr_id, read_fn, samples_ets, total_ops, start_time, batch_size)
    end)
  end

  defp reader_loop(reader_id, vdr_id, read_fn, samples_ets, total_ops, start_time, batch_size) do
    # Check for stop signal (non-blocking)
    receive do
      :stop ->
        :ok
    after
      0 ->
        # Get the read operation and hit checker
        {read_op, hit_check} = read_fn.()

        # Run batch_size operations and collect results
        batch_start = System.monotonic_time(:microsecond)

        results =
          for _ <- 1..batch_size do
            read_op.(vdr_id)
          end

        batch_end = System.monotonic_time(:microsecond)

        # Calculate batch metrics
        batch_duration = batch_end - batch_start
        avg_latency = div(batch_duration, batch_size)
        hits = Enum.count(results, &hit_check.(&1))

        # Increment total ops counter
        :counters.add(total_ops, 1, batch_size)

        # Record sample: {reader_id, relative_time, avg_latency_us, hits, batch_size}
        relative_time = batch_end - start_time
        :ets.insert(samples_ets, {reader_id, relative_time, avg_latency, hits, batch_size})

        reader_loop(reader_id, vdr_id, read_fn, samples_ets, total_ops, start_time, batch_size)
    end
  end

  defp collect_metrics(state, end_time) do
    duration_us = end_time - state.start_time
    total_ops = :counters.get(state.total_ops, 1)

    # Collect all samples from ETS
    all_samples =
      :ets.tab2list(state.samples_ets)
      |> Enum.map(fn {_reader_id, time, avg_latency, hits, batch_size} ->
        hit_rate = hits / batch_size
        {time, avg_latency, hit_rate}
      end)
      |> Enum.sort_by(fn {time, _, _} -> time end)

    # Calculate total hits/misses
    raw_samples = :ets.tab2list(state.samples_ets)
    total_hits = Enum.reduce(raw_samples, 0, fn {_, _, _, hits, _}, acc -> acc + hits end)
    total_sampled = Enum.reduce(raw_samples, 0, fn {_, _, _, _, batch_size}, acc -> acc + batch_size end)
    total_misses = total_sampled - total_hits

    tps =
      if duration_us > 0 do
        total_ops / (duration_us / 1_000_000)
      else
        0.0
      end

    %{
      total_ops: total_ops,
      duration_us: duration_us,
      tps: tps,
      latency_samples: all_samples,
      total_hits: total_hits,
      total_misses: total_misses
    }
  end
end
