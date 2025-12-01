#!/bin/bash
# Generate plots from benchmark results using gnuplot
#
# Usage: ./plot.sh [scenario_name]
#
# If no scenario name is provided, plots all scenarios.
# Requires gnuplot to be installed.

set -e

RESULTS_DIR="results"
PLOTS_DIR="plots"

# Check if gnuplot is installed
if ! command -v gnuplot &> /dev/null; then
    echo "Error: gnuplot is not installed"
    echo "Please install gnuplot:"
    echo "  Ubuntu/Debian: sudo apt-get install gnuplot"
    echo "  macOS: brew install gnuplot"
    echo "  Fedora: sudo dnf install gnuplot"
    exit 1
fi

# Create plots directory
mkdir -p "$PLOTS_DIR"

# Function to plot a single scenario
plot_scenario() {
    local csv_file="$1"
    local scenario_name=$(basename "$csv_file" .csv)
    local png_file="$PLOTS_DIR/${scenario_name}.png"

    echo "Plotting $scenario_name..."

    # Create gnuplot script
    gnuplot <<EOF
set terminal png size 1200,800 font "Arial,12"
set output '$png_file'

set title "Replication Lag - $scenario_name" font "Arial,16"
set xlabel "Time (ms)" font "Arial,14"
set ylabel "Lag (ms)" font "Arial,14"

set grid
set key top left

set datafile separator ","

# Skip header line
plot '$csv_file' every ::1 using 1:2 with lines linewidth 2 linecolor rgb "blue" title "Replication Lag"
EOF

    echo "  Saved to $png_file"
}

# Function to create combined plot for each data type
plot_combined() {
    local data_type="$1"
    local png_file="$PLOTS_DIR/${data_type}_combined.png"

    # Find all CSV files for this data type
    local csv_files=$(ls "$RESULTS_DIR"/${data_type}_*.csv 2>/dev/null || echo "")

    if [ -z "$csv_files" ]; then
        return
    fi

    echo "Creating combined plot for $data_type..."

    # Create gnuplot script for combined plot
    gnuplot <<EOF
set terminal png size 1400,900 font "Arial,12"
set output '$png_file'

set title "Replication Lag Comparison - $data_type" font "Arial,16"
set xlabel "Time (ms)" font "Arial,14"
set ylabel "Lag (ms)" font "Arial,14"

set grid
set key top left

set datafile separator ","

plot $(for csv in $csv_files; do
    scenario=$(basename "$csv" .csv)
    intensity=$(echo "$scenario" | sed 's/.*_//')
    echo "'$csv' every ::1 using 1:2 with lines linewidth 2 title '$intensity intensity',"
done | sed 's/,$//')
EOF

    echo "  Saved to $png_file"
}

# Main execution
if [ $# -eq 1 ]; then
    # Plot specific scenario
    scenario="$1"
    csv_file="$RESULTS_DIR/${scenario}.csv"

    if [ ! -f "$csv_file" ]; then
        echo "Error: Results file not found: $csv_file"
        echo "Available scenarios:"
        ls "$RESULTS_DIR"/*.csv 2>/dev/null | xargs -n 1 basename -s .csv | sed 's/^/  - /'
        exit 1
    fi

    plot_scenario "$csv_file"
else
    # Plot all scenarios
    csv_files=$(ls "$RESULTS_DIR"/*.csv 2>/dev/null || echo "")

    if [ -z "$csv_files" ]; then
        echo "No result files found in $RESULTS_DIR/"
        echo "Run the benchmark first:"
        echo "  mix run run_benchmarks.exs"
        exit 1
    fi

    echo "=== Generating plots for all scenarios ==="
    echo ""

    # Plot individual scenarios
    for csv_file in $csv_files; do
        plot_scenario "$csv_file"
    done

    echo ""
    echo "=== Generating combined plots ==="
    echo ""

    # Plot combined graphs for each data type
    for data_type in strings hashes lists sets; do
        plot_combined "$data_type"
    done
fi

echo ""
echo "=== All plots generated ==="
echo "Plots saved to $PLOTS_DIR/"
echo ""
echo "View plots:"
ls "$PLOTS_DIR"/*.png 2>/dev/null | sed 's/^/  /'
