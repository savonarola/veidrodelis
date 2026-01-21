defmodule Mix.Tasks.Benchmark do
  @moduledoc """
  Run Veidrodelis replication lag benchmarks.

  ## Usage

      mix benchmark [scenario_name] [options]

  ## Options

      --duration SECONDS   Override scenario duration
      --intensity N        Override commands per second
      --readers N          Override number of reader processes
      --list               List available scenarios

  ## Examples

      # Run all scenarios
      mix benchmark

      # Run specific scenario
      mix benchmark strings_low

      # Run with custom parameters
      mix benchmark hashes_100k --duration 30 --intensity 50000 --readers 2

      # List available scenarios
      mix benchmark --list

  ## Available Scenarios

  - strings_low, strings_medium, strings_high
  - hashes_low, hashes_medium, hashes_high
  - lists_low, lists_medium, lists_high
  - sets_low, sets_medium, sets_high

  ## Prerequisites

  - Redis running on localhost:6379 without password
  - gnuplot installed (for generating plots)

  ## Output

  Results are saved to:
  - benchmark/results/ (CSV files)

  To generate plots, run:
      cd benchmark && ./plot.sh
  """

  use Mix.Task

  alias Vdr.Benchmark.{LagTracker, ScenarioRunner}
  alias Vdr.Benchmark.Scenarios.{StringCommands, HashCommands, ListCommands, SetCommands}

  @redis_host "localhost"
  @redis_port 6379
  @vdr_id :benchmark_vdr

  @shortdoc "Run Veidrodelis replication lag benchmarks"

  @impl Mix.Task
  def run(args) do
    # Start required applications
    {:ok, _} = Application.ensure_all_started(:veidrodelis)
    {:ok, _} = Application.ensure_all_started(:redix)

    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [list: :boolean, duration: :integer, intensity: :integer, readers: :integer]
      )

    overrides = %{
      duration: Keyword.get(opts, :duration),
      intensity: Keyword.get(opts, :intensity),
      readers: Keyword.get(opts, :readers)
    }

    case {positional, opts} do
      {_, [list: true]} ->
        list_scenarios()

      {[scenario_filter], _opts} ->
        run_benchmarks(scenario_filter, overrides)

      {[], _opts} ->
        run_benchmarks(nil, overrides)

      _ ->
        Mix.shell().error("Invalid arguments. Usage: mix benchmark [scenario_name] [options]")
        Mix.shell().info("Run 'mix benchmark --list' to see available scenarios")
    end
  end

  defp list_scenarios do
    Mix.shell().info("Available benchmark scenarios:")
    Mix.shell().info("")

    all_scenarios = get_all_scenarios()

    Enum.each(all_scenarios, fn scenario ->
      Mix.shell().info("  #{scenario.name}")
      Mix.shell().info("    Duration: #{scenario.duration_seconds}s")
      Mix.shell().info("    Intensity: #{scenario.intensity} commands/sec")
      Mix.shell().info("    Readers: #{Map.get(scenario, :reader_count, 0)}")
      Mix.shell().info("")
    end)
  end

  defp run_benchmarks(scenario_filter, overrides) do
    Logger.configure(level: :info)
    Mix.shell().info("=== Veidrodelis Replication Lag Benchmark ===")
    Mix.shell().info("")

    # Collect all scenarios
    all_scenarios = get_all_scenarios()

    # Filter scenarios if requested
    scenarios =
      if scenario_filter do
        filtered = Enum.filter(all_scenarios, fn s -> s.name == scenario_filter end)

        if Enum.empty?(filtered) do
          Mix.shell().error("Error: Unknown scenario '#{scenario_filter}'")
          Mix.shell().info("")
          Mix.shell().info("Available scenarios:")

          Enum.each(all_scenarios, fn s ->
            Mix.shell().info("  - #{s.name}")
          end)

          exit({:shutdown, 1})
        end

        filtered
      else
        all_scenarios
      end

    # Apply overrides if specified
    scenarios = Enum.map(scenarios, fn s -> apply_overrides(s, overrides) end)

    Mix.shell().info("Running #{length(scenarios)} scenario(s):")
    Mix.shell().info("")

    Enum.each(scenarios, fn s ->
      Mix.shell().info("  - #{s.name}")
    end)

    Mix.shell().info("")

    # Ensure results directory exists
    File.mkdir_p!("benchmark/results")

    # Setup
    {:ok, redis_conn} = setup_redis()
    {:ok, vdr_pid} = setup_veidrodelis()
    {:ok, _tracker_pid} = setup_lag_tracker(redis_conn)

    # Run scenarios
    _results =
      Enum.map(scenarios, fn scenario ->
        run_scenario(redis_conn, scenario)
      end)

    # Dump lag statistics
    Mix.shell().info("")

    # Cleanup
    cleanup(redis_conn, vdr_pid)

    # Report
    Mix.shell().info("")
    Mix.shell().info("=== Benchmark Complete ===")
    Mix.shell().info("")
    Mix.shell().info("Results saved to benchmark/results/")
    Mix.shell().info("")
    Mix.shell().info("To generate plots, run:")
    Mix.shell().info("  cd benchmark && ./plot.sh")
    Mix.shell().info("")
  end

  defp get_all_scenarios do
    StringCommands.scenarios() ++
      HashCommands.scenarios() ++
      ListCommands.scenarios() ++
      SetCommands.scenarios()
  end

  defp apply_overrides(scenario, overrides) do
    scenario
    |> maybe_override(:duration_seconds, overrides.duration)
    |> maybe_override(:intensity, overrides.intensity)
    |> maybe_override(:reader_count, overrides.readers)
  end

  defp maybe_override(scenario, _key, nil), do: scenario
  defp maybe_override(scenario, key, value), do: Map.put(scenario, key, value)

  defp setup_redis do
    Mix.shell().info("Connecting to Redis at #{@redis_host}:#{@redis_port}...")

    case Redix.start_link(host: @redis_host, port: @redis_port) do
      {:ok, conn} ->
        Mix.shell().info("Connected to Redis")

        # Flush all data
        Mix.shell().info("Flushing Redis database...")
        Redix.command!(conn, ["FLUSHALL"])
        Mix.shell().info("Redis ready")

        {:ok, conn}

      {:error, reason} ->
        Mix.shell().error("Error: Failed to connect to Redis: #{inspect(reason)}")
        Mix.shell().info("")
        Mix.shell().info("Make sure Redis is running on #{@redis_host}:#{@redis_port}")
        exit({:shutdown, 1})
    end
  end

  defp setup_veidrodelis do
    Mix.shell().info("Starting Veidrodelis replica...")

    case Veidrodelis.start_link(
           id: @vdr_id,
           host: @redis_host,
           port: @redis_port,
           command_filter: LagTracker.command_filter()
         ) do
      {:ok, pid} ->
        # Wait for replication to start
        wait_for_replication(pid)
        Mix.shell().info("Veidrodelis replica started")
        {:ok, pid}

      {:error, reason} ->
        Mix.shell().error("Error: Failed to start Veidrodelis: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp wait_for_replication(pid, attempts \\ 0) do
    if attempts > 50 do
      Mix.shell().error("Error: Veidrodelis did not enter streaming state")
      exit({:shutdown, 1})
    end

    case Veidrodelis.get_replication_state(pid) do
      :streaming ->
        :ok

      state ->
        Mix.shell().info("  Replication state: #{state}")
        Process.sleep(100)
        wait_for_replication(pid, attempts + 1)
    end
  end

  defp setup_lag_tracker(redis_conn) do
    Mix.shell().info("Starting lag tracker...")

    case LagTracker.start_link(
           vdr_id: @vdr_id,
           tracker_key: "lagmon",
           redis_conn: redis_conn,
           timestamp_interval_ms: 1000
         ) do
      {:ok, pid} ->
        Mix.shell().info("Lag tracker started (injecting timestamps every 1000ms)")
        {:ok, pid}

      {:error, reason} ->
        Mix.shell().error("Error: Failed to start lag tracker: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp run_scenario(redis_conn, scenario) do
    # Flush before each scenario
    Redix.command!(redis_conn, ["FLUSHALL"])
    Process.sleep(500)

    opts =
      scenario
      |> Map.put(:redis_conn, redis_conn)
      |> Map.put(:vdr_id, @vdr_id)
      |> Enum.into([])

    result = ScenarioRunner.run(opts)

    # Save results to CSV
    ScenarioRunner.write_results_to_csv(result, "benchmark/results")

    result
  end

  defp cleanup(redis_conn, vdr_pid) do
    Mix.shell().info("")
    Mix.shell().info("Cleaning up...")
    Redix.stop(redis_conn)
    Veidrodelis.stop(vdr_pid)
    Mix.shell().info("Cleanup complete")
  end
end
