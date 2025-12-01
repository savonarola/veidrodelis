defmodule Vdr.Benchmark.ScenarioRunner do
  @moduledoc """
  Runs benchmark scenarios and collects metrics.
  """

  @doc """
  Runs a benchmark scenario.

  Options:
    * `:name` - Scenario name
    * `:duration_seconds` - How long to run the scenario
    * `:intensity` - Commands per second
    * `:command_fn` - Function that generates commands
    * `:redis_conn` - Redix connection PID
  """
  def run(opts) do
    name = Keyword.fetch!(opts, :name)
    duration_seconds = Keyword.fetch!(opts, :duration_seconds)
    intensity = Keyword.fetch!(opts, :intensity)
    command_fn = Keyword.fetch!(opts, :command_fn)
    redis_conn = Keyword.fetch!(opts, :redis_conn)

    IO.puts("\n=== Running scenario: #{name} ===")
    IO.puts("Duration: #{duration_seconds}s")
    IO.puts("Intensity: #{intensity} commands/sec")

    # Reset lag tracker
    Vdr.Benchmark.LagTracker.reset()

    # Calculate timing
    end_time = System.monotonic_time(:millisecond) + duration_seconds * 1000

    # Start command loop - send commands in batches per second
    command_count = execute_command_loop(
      redis_conn,
      command_fn,
      intensity,
      end_time,
      0
    )

    # Wait a bit for final replication
    Process.sleep(1000)

    # Collect results
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

    %{
      name: name,
      command_count: command_count,
      lag_samples: lag_samples,
      duration_seconds: duration_seconds,
      intensity: intensity
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
      commands = for _ <- 1..intensity, do: command_fn.()

      # Send all commands in a pipeline
      Redix.pipeline!(redis_conn, commands)

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

  @doc """
  Writes benchmark results to CSV file.
  """
  def write_results_to_csv(results, output_file) do
    csv_content =
      "time_ms,lag_ms\n" <>
        (results.lag_samples
         |> Enum.map(fn {time, lag} -> "#{time},#{lag}" end)
         |> Enum.join("\n"))

    File.write!(output_file, csv_content)
    IO.puts("Results written to #{output_file}")
  end
end
