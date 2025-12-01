defmodule Mix.Tasks.Benchmark do
  @moduledoc """
  Run Veidrodelis replication lag benchmarks.

  ## Usage

      mix benchmark [scenario_name]

  ## Examples

      # Run all scenarios
      mix benchmark

      # Run specific scenario
      mix benchmark strings_low

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

  alias Vdr.Benchmark.{PassthroughDecoder, LagTracker, ScenarioRunner}
  alias Vdr.Benchmark.Scenarios.{StringCommands, HashCommands, ListCommands, SetCommands}

  @redis_host "localhost"
  @redis_port 6379
  @vdr_id :benchmark_vdr
  @tracker_key "_ts"

  @shortdoc "Run Veidrodelis replication lag benchmarks"

  @impl Mix.Task
  def run(args) do
    # Start required applications
    {:ok, _} = Application.ensure_all_started(:veidrodelis)
    {:ok, _} = Application.ensure_all_started(:redix)

    case args do
      ["--list"] ->
        list_scenarios()

      [scenario_filter] ->
        run_benchmarks(scenario_filter)

      [] ->
        run_benchmarks(nil)

      _ ->
        Mix.shell().error("Invalid arguments. Usage: mix benchmark [scenario_name]")
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
      Mix.shell().info("")
    end)
  end

  defp run_benchmarks(scenario_filter) do
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
           decoder: PassthroughDecoder,
           host: @redis_host,
           port: @redis_port
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
           tracker_key: @tracker_key,
           redis_conn: redis_conn,
           timestamp_interval_ms: 500
         ) do
      {:ok, pid} ->
        Mix.shell().info("Lag tracker started (injecting timestamps every 500ms)")
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
      |> Enum.into([])

    result = ScenarioRunner.run(opts)

    # Save results to CSV
    output_file = "benchmark/results/#{scenario.name}.csv"
    ScenarioRunner.write_results_to_csv(result, output_file)

    result
  end

  defp cleanup(redis_conn, vdr_pid) do

    hash_store = Veidrodelis.hashes(@vdr_id)
    ets = hash_store.tid
    Mix.shell().info("ETS: #{inspect(:ets.info(ets))}")

    Mix.shell().info("")
    Mix.shell().info("Cleaning up...")
    Redix.stop(redis_conn)
    Veidrodelis.stop(vdr_pid)
    Mix.shell().info("Cleanup complete")
  end
end
