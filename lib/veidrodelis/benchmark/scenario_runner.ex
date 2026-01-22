defmodule Vdr.Benchmark.ScenarioRunner do
  @moduledoc """
  Runs benchmark scenarios and collects metrics.
  """

  alias Vdr.Benchmark.Reader

  @pipeline_batch_size 100

  @doc """
  Runs a benchmark scenario.

  Options:
    * `:name` - Scenario name
    * `:duration_seconds` - How long to run the scenario
    * `:intensity` - Commands per second
    * `:command_fn` - Function that generates commands
    * `:redis_conn` - Redix connection PID
    * `:vdr_id` - Veidrodelis instance ID (required for readers)
    * `:reader_count` - Number of reader processes (optional, 0 = no readers)
    * `:read_fn` - Function that generates read operations (required if reader_count > 0)
  """
  def run(opts) do
    name = Keyword.fetch!(opts, :name)
    duration_seconds = Keyword.fetch!(opts, :duration_seconds)
    intensity = Keyword.fetch!(opts, :intensity)
    command_fn = Keyword.fetch!(opts, :command_fn)
    redis_conn = Keyword.fetch!(opts, :redis_conn)
    vdr_id = Keyword.fetch!(opts, :vdr_id)
    reader_count = Keyword.get(opts, :reader_count, 0)
    read_fn = Keyword.get(opts, :read_fn)

    IO.puts("\n=== Running scenario: #{name} ===")
    IO.puts("Duration: #{duration_seconds}s")
    IO.puts("Intensity: #{intensity} commands/sec")
    IO.puts("Reader processes: #{reader_count}")

    # Reset lag tracker
    Vdr.Benchmark.LagTracker.reset()

    # Start readers if configured
    reader_pid =
      if reader_count > 0 and read_fn != nil do
        {:ok, pid} =
          Reader.start_link(
            vdr_id: vdr_id,
            reader_count: reader_count,
            read_fn: read_fn
          )

        Reader.start_readers()
        pid
      else
        nil
      end

    # Calculate timing
    end_time = System.monotonic_time(:millisecond) + duration_seconds * 1000

    # Start command loop - send commands in batches per second
    command_count =
      execute_command_loop(
        redis_conn,
        command_fn,
        intensity,
        end_time,
        0
      )

    # Wait a bit for final replication
    Process.sleep(1000)

    # Stop readers and collect metrics
    reader_metrics =
      if reader_pid do
        metrics = Reader.stop_readers()
        GenServer.stop(reader_pid)
        metrics
      else
        nil
      end

    # Collect lag results
    lag_samples = Vdr.Benchmark.LagTracker.get_lag_samples()

    IO.puts("\nCompleted!")
    IO.puts("Commands executed: #{command_count}")
    IO.puts("Lag samples collected: #{length(lag_samples)}")

    if length(lag_samples) > 0 do
      lags = Enum.map(lag_samples, fn {_time, lag} -> lag end)
      avg_lag = Enum.sum(lags) / length(lags)
      max_lag = Enum.max(lags)
      min_lag = Enum.min(lags)

      IO.puts("Average lag: #{Float.round(avg_lag, 2)}ms")
      IO.puts("Min lag: #{min_lag}ms")
      IO.puts("Max lag: #{max_lag}ms")
    end

    if reader_metrics do
      IO.puts("\nReader metrics:")
      IO.puts("  Total read ops: #{reader_metrics.total_ops}")
      IO.puts("  Read TPS: #{Float.round(reader_metrics.tps, 0)}")
      IO.puts("  Hits: #{reader_metrics.total_hits}, Misses: #{reader_metrics.total_misses}")

      if length(reader_metrics.latency_samples) > 0 do
        latencies = Enum.map(reader_metrics.latency_samples, fn {_, lat, _} -> lat end)
        avg_lat = Enum.sum(latencies) / length(latencies)
        IO.puts("  Avg read latency: #{Float.round(avg_lat, 2)}us")
      end
    end

    %{
      name: name,
      command_count: command_count,
      lag_samples: lag_samples,
      duration_seconds: duration_seconds,
      intensity: intensity,
      reader_metrics: reader_metrics
    }
  end

  defp execute_command_loop(redis_conn, command_fn, intensity, end_time, count) do
    current_time = System.monotonic_time(:millisecond)

    if current_time >= end_time do
      count
    else
      # Mark start of this batch
      batch_start = System.monotonic_time(:millisecond)

      # Generate commands for this second
      run_commands(command_fn, redis_conn, @pipeline_batch_size, intensity, [])

      # Calculate elapsed time
      elapsed_ms = System.monotonic_time(:millisecond) - batch_start

      IO.puts("Batch took #{elapsed_ms}ms, intensity: #{intensity}")

      # Warn if we can't keep up with the desired intensity
      if elapsed_ms > 1000 do
        IO.puts(
          "Warning: Batch took #{elapsed_ms}ms (> 1000ms). " <>
            "Cannot maintain #{intensity} commands/sec. Consider reducing intensity."
        )
      end

      # Sleep for the rest of the second
      sleep_ms = max(0, 1000 - elapsed_ms)

      if sleep_ms > 0 do
        Process.sleep(sleep_ms)
      end

      execute_command_loop(redis_conn, command_fn, intensity, end_time, count + intensity)
    end
  end


  defp run_commands(_command_fn, redis_conn, _batch_left, 0, commands) do
    Redix.pipeline!(redis_conn, commands)
    :ok
  end

  defp run_commands(command_fn, redis_conn, 0, total_left, commands) do
    Redix.pipeline!(redis_conn, commands)
    run_commands(command_fn, redis_conn, @pipeline_batch_size, total_left, [])
  end

  defp run_commands(command_fn, redis_conn, batch_left, total_left, commands) do
    run_commands(command_fn, redis_conn, batch_left - 1, total_left - 1, [command_fn.() | commands])
  end

  @doc """
  Writes benchmark results to CSV files.

  Creates two files:
    * `{output_dir}/{name}_lag.csv` - Replication lag samples
    * `{output_dir}/{name}_reads.csv` - Reader latency samples (if readers were used)
  """
  def write_results_to_csv(results, output_dir) do
    name = results.name

    # Write lag samples
    lag_file = Path.join(output_dir, "#{name}_lag.csv")

    lag_content =
      "time_us,lag_us\n" <>
        (results.lag_samples
         |> Enum.map(fn {time, lag} -> "#{time},#{lag}" end)
         |> Enum.join("\n"))

    File.write!(lag_file, lag_content)
    IO.puts("Lag results written to #{lag_file}")

    # Write reader samples if available
    if results.reader_metrics && length(results.reader_metrics.latency_samples) > 0 do
      reads_file = Path.join(output_dir, "#{name}_reads.csv")

      reads_content =
        "time_us,avg_latency_us,hit_rate\n" <>
          (results.reader_metrics.latency_samples
           |> Enum.map(fn {time, latency, hit_rate} ->
             "#{time},#{latency},#{Float.round(hit_rate, 4)}"
           end)
           |> Enum.join("\n"))

      File.write!(reads_file, reads_content)
      IO.puts("Read results written to #{reads_file}")

      # Write summary stats
      summary_file = Path.join(output_dir, "#{name}_summary.csv")

      summary_content =
        "metric,value\n" <>
          "total_read_ops,#{results.reader_metrics.total_ops}\n" <>
          "read_tps,#{Float.round(results.reader_metrics.tps, 2)}\n" <>
          "total_hits,#{results.reader_metrics.total_hits}\n" <>
          "total_misses,#{results.reader_metrics.total_misses}\n" <>
          "duration_us,#{results.reader_metrics.duration_us}"

      File.write!(summary_file, summary_content)
      IO.puts("Summary written to #{summary_file}")
    end
  end
end
