#!/bin/bash
# Run benchmark with profiling and generate flamegraphs
#
# Usage: ./bench-profile.sh [scenario] [duration] [intensity] [readers]
#
# This script:
# 1. Starts the benchmark with perf support enabled (ERL_FLAGS="+JPperf true")
# 2. Finds the BEAM process and profiles it
# 3. Generates flamegraphs in benchmark/plots/

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

SCENARIO="${1:-hashes_100k}"
DURATION="${2:-30}"
INTENSITY="${3:-50000}"
READERS="${4:-1}"

# Clean previous results
rm -f "$PROJECT_DIR/benchmark/results"/*.csv
rm -f "$PROJECT_DIR/benchmark/plots"/*.png
rm -f "$PROJECT_DIR/benchmark/plots"/*.svg

echo "=== Running benchmark with profiling: $SCENARIO ==="
echo "  Duration: ${DURATION}s, Intensity: ${INTENSITY} cmd/s, Readers: ${READERS}"
echo ""

just clean
RUSTFLAGS="-C force-frame-pointers=yes" just compile

# Start benchmark in background with perf support
cd "$PROJECT_DIR"
ERL_FLAGS="+JPperf true" mix benchmark "$SCENARIO" --duration "$DURATION" --intensity "$INTENSITY" --readers "$READERS" &
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

# Calculate profile duration: benchmark duration minus 10s threshold (minimum 5s)
# This allows time for benchmark startup/warmup and cleanup
PROFILE_THRESHOLD=3
PROFILE_MIN=5
PROFILE_DURATION=$((DURATION - PROFILE_THRESHOLD))
if [ "$PROFILE_DURATION" -lt "$PROFILE_MIN" ]; then
    PROFILE_DURATION=$PROFILE_MIN
fi

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
