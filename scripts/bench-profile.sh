#!/bin/bash
# Run benchmark with profiling and generate flamegraphs
#
# Usage: ./bench-profile.sh [scenario]
#
# This script:
# 1. Starts the benchmark with perf support enabled (ERL_FLAGS="+JPperf true")
# 2. Finds the BEAM process and profiles it
# 3. Generates flamegraphs in benchmark/plots/

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

SCENARIO="${1:-hashes_100k}"

# Clean previous results
rm -f "$PROJECT_DIR/benchmark/results"/*.csv
rm -f "$PROJECT_DIR/benchmark/plots"/*.png
rm -f "$PROJECT_DIR/benchmark/plots"/*.svg

echo "=== Running benchmark with profiling: $SCENARIO ==="
echo ""

# Start benchmark in background with perf support
cd "$PROJECT_DIR"
ERL_FLAGS="+JPperf true" mix benchmark "$SCENARIO" &
BENCH_PID=$!

# Wait a moment for the BEAM to start
sleep 2

# Find the beam.smp process (the actual BEAM VM)
BEAM_PID=$(pgrep -f "beam.smp.*benchmark" | head -1)

if [ -z "$BEAM_PID" ]; then
    echo "Error: Could not find BEAM process"
    kill $BENCH_PID 2>/dev/null || true
    exit 1
fi

echo "Found BEAM process: $BEAM_PID"
echo "Benchmark process: $BENCH_PID"

# Get the duration from the scenario (rough estimate - profile for most of the run)
# We'll profile for a fixed duration and let the benchmark complete
PROFILE_DURATION=10

echo "Profiling for $PROFILE_DURATION seconds..."

# Profile the BEAM process
OUTPUT_PREFIX="$PROJECT_DIR/benchmark/plots/${SCENARIO}"
"$SCRIPT_DIR/profile.sh" "$BEAM_PID" "$PROFILE_DURATION" "$OUTPUT_PREFIX" &
PROFILE_PID=$!

# Wait for benchmark to complete
wait $BENCH_PID
BENCH_EXIT=$?

# Wait for profiling to complete (if still running)
wait $PROFILE_PID 2>/dev/null || true

if [ $BENCH_EXIT -ne 0 ]; then
    echo "Benchmark failed with exit code $BENCH_EXIT"
    exit $BENCH_EXIT
fi

# Generate plots
echo ""
echo "Generating plots..."
cd "$PROJECT_DIR/benchmark" && ./plot.sh

echo ""
echo "=== Profiling complete ==="
echo ""
echo "Results:"
ls -la "$PROJECT_DIR/benchmark/plots"/*.svg 2>/dev/null || echo "No flamegraphs generated"
ls -la "$PROJECT_DIR/benchmark/plots"/*.png 2>/dev/null || echo "No plots generated"
