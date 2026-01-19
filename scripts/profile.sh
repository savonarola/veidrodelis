#!/bin/bash
# Profile a process and generate flamegraph
#
# Usage: ./profile.sh <PID> <DURATION_SECONDS> <OUTPUT_PREFIX>
#
# Example: ./profile.sh 12345 10 benchmark/plots/hashes_100k

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PID=$1
DURATION=$2
OUTPUT_PREFIX=$3

if [ -z "$PID" ] || [ -z "$DURATION" ] || [ -z "$OUTPUT_PREFIX" ]; then
    echo "Usage: $0 <PID> <DURATION_SECONDS> <OUTPUT_PREFIX>"
    echo "Example: $0 12345 10 benchmark/plots/hashes_100k"
    exit 1
fi

PERF_DATA="${OUTPUT_PREFIX}_perf.data"
PERF_SCRIPT="${OUTPUT_PREFIX}_perf.txt"
FOLDED="${OUTPUT_PREFIX}.folded"
SVG="${OUTPUT_PREFIX}_flamegraph.svg"

echo "Profiling PID $PID for $DURATION seconds..."

# Record with perf
sudo perf record --call-graph=fp -o "$PERF_DATA" --pid "$PID" -- sleep "$DURATION"

# Change ownership so we can read it
sudo chown "$USER" "$PERF_DATA"

# Convert to script format
perf script -i "$PERF_DATA" > "$PERF_SCRIPT"

# Collapse stacks
"$SCRIPT_DIR/stackcollapse-perf.pl" "$PERF_SCRIPT" > "$FOLDED"

# Generate flamegraph
"$SCRIPT_DIR/flamegraph.pl" "$FOLDED" > "$SVG"

echo "Flamegraph saved to: $SVG"

# Cleanup intermediate files
rm -f "$PERF_DATA" "$PERF_SCRIPT" "$FOLDED"
