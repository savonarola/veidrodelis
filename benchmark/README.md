# Veidrodelis Replication Lag Benchmarks

This directory contains benchmark scripts for measuring replication lag in Veidrodelis across different Redis command patterns and intensities.

## Overview

The benchmark suite tests replication lag by:

1. Connecting to a local Redis instance
2. Starting a Veidrodelis replica that connects to Redis
3. Issuing different groups of Redis commands at varying intensities
4. Periodically injecting timestamp markers into the data stream
5. Measuring the time difference between when commands are sent and when they're replicated
6. Generating plots showing replication lag over time

## Prerequisites

### Required

- **Redis**: Running on `localhost:6379` without a password
- **Elixir**: Version 1.14 or higher
- **Dependencies**: Run `mix deps.get` in the project root

### Optional (for plotting)

- **gnuplot**: For generating plots from results
  - Ubuntu/Debian: `sudo apt-get install gnuplot`
  - macOS: `brew install gnuplot`
  - Fedora: `sudo dnf install gnuplot`

## Quick Start

### 1. Setup Redis

Start a Redis instance on the default port:

```bash
redis-server --port 6379
```

Or use Docker:

```bash
docker run -d -p 6379:6379 redis:latest
```

### 2. Compile the Project

From the project root:

```bash
mix deps.get
mix compile
```

### 3. Run All Benchmarks

From the project root:

```bash
mix benchmark
```

This will run all scenarios and save results to the `benchmark/results/` directory.

### 4. Generate Plots

```bash
cd benchmark
./plot.sh
```

Plots will be saved to the `plots/` directory as PNG files.

## Benchmark Scenarios

The benchmark suite includes the following scenarios:

### String Commands
- **Commands**: `SET`, `DEL`
- **Scenarios**:
  - `strings_low`: 100 commands/sec for 30 seconds
  - `strings_medium`: 1,000 commands/sec for 30 seconds
  - `strings_high`: 5,000 commands/sec for 30 seconds

### Hash Commands
- **Commands**: `HSET`, `HDEL`
- **Scenarios**:
  - `hashes_low`: 100 commands/sec for 30 seconds
  - `hashes_medium`: 1,000 commands/sec for 30 seconds
  - `hashes_high`: 5,000 commands/sec for 30 seconds

### List Commands
- **Commands**: `LPUSH`, `RPUSH`, `DEL`
- **Scenarios**:
  - `lists_low`: 100 commands/sec for 30 seconds
  - `lists_medium`: 1,000 commands/sec for 30 seconds
  - `lists_high`: 5,000 commands/sec for 30 seconds

### Set Commands
- **Commands**: `SADD`, `SREM`
- **Scenarios**:
  - `sets_low`: 100 commands/sec for 30 seconds
  - `sets_medium`: 1,000 commands/sec for 30 seconds
  - `sets_high`: 5,000 commands/sec for 30 seconds

## Usage

### Run Specific Scenario

To run a single scenario:

```bash
mix benchmark strings_low
```

### List Available Scenarios

```bash
mix benchmark --list
```

### Generate Plots

Plot all scenarios:

```bash
cd benchmark
./plot.sh
```

Plot specific scenario:

```bash
cd benchmark
./plot.sh strings_low
```

## How Lag Measurement Works

The benchmark measures replication lag using timestamp markers:

1. **Injection**: Every 500ms, the benchmark injects a timestamp marker:
   ```
   DEL _ts
   LPUSH _ts <current_timestamp_ms>
   ```

2. **Detection**: The lag tracker monitors the Veidrodelis list store for updates to the `_ts` key

3. **Calculation**: When a timestamp is detected:
   ```
   lag_ms = current_time_ms - replicated_timestamp_ms
   ```

4. **Collection**: Lag samples are collected throughout the benchmark run

This approach measures end-to-end replication lag including:
- Redis command processing
- Replication protocol overhead
- Network latency
- Veidrodelis processing time

## Output Files

### Results Directory

CSV files containing timestamp and lag data:

```
results/
  strings_low.csv
  strings_medium.csv
  strings_high.csv
  hashes_low.csv
  ...
```

CSV format:
```
time_ms,lag_ms
0,5
512,7
1024,6
...
```

### Plots Directory

PNG plots showing lag over time:

```
plots/
  strings_low.png          # Individual scenario plots
  strings_medium.png
  strings_high.png
  strings_combined.png     # Combined comparison plots
  hashes_combined.png
  lists_combined.png
  sets_combined.png
  ...
```

## Project Structure

```
lib/
├── mix/
│   └── tasks/
│       └── benchmark.ex           # Mix task for running benchmarks
└── veidrodelis/
    └── benchmark/
        ├── passthrough_decoder.ex # Simple decoder for benchmarks
        ├── lag_tracker.ex         # Tracks replication lag
        ├── scenario_runner.ex     # Executes benchmark scenarios
        └── scenarios/
            ├── string_commands.ex # String command scenarios
            ├── hash_commands.ex   # Hash command scenarios
            ├── list_commands.ex   # List command scenarios
            └── set_commands.ex    # Set command scenarios

benchmark/
├── README.md                      # This file
├── plot.sh                        # Plotting script
├── check_prereqs.sh               # Prerequisites checker
├── results/                       # Generated CSV files
└── plots/                         # Generated PNG plots
```

## Customization

### Adding New Scenarios

1. Create a new scenario module in `lib/veidrodelis/benchmark/scenarios/`:

```elixir
defmodule Vdr.Benchmark.Scenarios.MyCommands do
  @moduledoc """
  Benchmark scenario for my custom commands.
  """

  def scenarios do
    [
      %{
        name: "my_scenario",
        duration_seconds: 30,
        intensity: 1000,
        command_fn: &generate_command/0,
        timestamp_fn: &generate_timestamp_marker/2,
        timestamp_interval_ms: 500,
        tracker_key: "_ts"
      }
    ]
  end

  defp generate_command do
    ["SET", "key", "value"]
  end

  defp generate_timestamp_marker(tracker_key, timestamp_ms) do
    [
      ["DEL", tracker_key],
      ["LPUSH", tracker_key, Integer.to_string(timestamp_ms)]
    ]
  end
end
```

2. Add the alias and include scenarios in `lib/mix/tasks/benchmark.ex`:

```elixir
alias Vdr.Benchmark.Scenarios.{StringCommands, HashCommands, ListCommands, SetCommands, MyCommands}

# In get_all_scenarios/0
defp get_all_scenarios do
  StringCommands.scenarios() ++
    HashCommands.scenarios() ++
    ListCommands.scenarios() ++
    SetCommands.scenarios() ++
    MyCommands.scenarios()
end
```

3. Compile and run:

```bash
mix compile
mix benchmark my_scenario
```

### Adjusting Parameters

Modify scenario parameters in the scenario files:

- `duration_seconds`: How long to run the scenario
- `intensity`: Commands per second
- `timestamp_interval_ms`: How often to inject timestamps (lower = more samples, higher overhead)

### Different Redis Connection

Edit `lib/mix/tasks/benchmark.ex` and modify:

```elixir
@redis_host "localhost"
@redis_port 6379
```

## Interpreting Results

### What's Normal?

- **Low intensity** (100 cmd/s): Lag should be < 10ms
- **Medium intensity** (1,000 cmd/s): Lag typically < 50ms
- **High intensity** (5,000 cmd/s): Lag varies, may spike during bulk operations

### Factors Affecting Lag

1. **Command complexity**: Hash/set operations may have higher lag than strings
2. **Data size**: Larger values increase replication time
3. **System load**: CPU/memory constraints affect performance
4. **Network**: Even local replication has TCP overhead
5. **Redis configuration**: AOF, RDB settings impact replication

### Troubleshooting High Lag

- Check Redis CPU/memory usage
- Verify network connectivity
- Review Redis replication backlog size
- Check for slow commands with `SLOWLOG`
- Monitor system resources

## Benchmarking Best Practices

1. **Baseline**: Run with no other load on Redis
2. **Consistency**: Run multiple times and average results
3. **Cleanup**: Restart Redis between major benchmark runs
4. **Monitoring**: Watch Redis metrics during benchmarks
5. **Validation**: Ensure Redis is not hitting memory limits

## Troubleshooting

### Redis Connection Errors

```
Error: Failed to connect to Redis
```

- Verify Redis is running: `redis-cli ping`
- Check port: `netstat -an | grep 6379`
- Review Redis logs

### Compilation Errors

```
Error: module not found
```

- Run `mix deps.get` from project root
- Run `mix compile` from project root
- Check Elixir version: `elixir --version`

### No Replication

```
Error: Veidrodelis did not enter streaming state
```

- Check Redis version (must support replication)
- Review Redis replication settings
- Check for connection errors in logs

### Plot Script Errors

```
Error: gnuplot is not installed
```

- Install gnuplot (see Prerequisites)
- Verify installation: `gnuplot --version`

## Contributing

To add new scenarios or improve benchmarks:

1. Create scenario files in `scenarios/`
2. Update `run_benchmarks.exs` to include new scenarios
3. Test with different intensities
4. Document expected behavior

## License

Same as the main Veidrodelis project.
