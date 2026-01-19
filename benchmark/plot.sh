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

# Function to plot replication lag
# Note: CSV has time_us and lag_us (despite header saying ms)
plot_lag() {
    local csv_file="$1"
    local scenario_name=$(basename "$csv_file" _lag.csv)
    local png_file="$PLOTS_DIR/${scenario_name}_lag.png"

    echo "Plotting lag for $scenario_name..."

    gnuplot <<EOF
set terminal png size 1200,800 font "Arial,12"
set output '$png_file'

set title "Replication Lag - $scenario_name" font "Arial,16"
set xlabel "Time (s)" font "Arial,14"
set ylabel "Lag (ms)" font "Arial,14"

set grid
set key top left

set datafile separator ","

# Convert: time us->s (col1/1e6), lag us->ms (col2/1000)
plot '$csv_file' every ::1 using (\$1/1e6):(\$2/1000) with lines linewidth 2 linecolor rgb "blue" title "Replication Lag"
EOF

    echo "  Saved to $png_file"
}

# Function to plot reader latency
plot_reads() {
    local csv_file="$1"
    local scenario_name=$(basename "$csv_file" _reads.csv)
    local png_file="$PLOTS_DIR/${scenario_name}_reads.png"

    echo "Plotting read latency for $scenario_name..."

    gnuplot <<EOF
set terminal png size 1200,800 font "Arial,12"
set output '$png_file'

set multiplot layout 2,1 title "Reader Metrics - $scenario_name" font "Arial,16"

# Top plot: Read latency over time
set title "Read Latency" font "Arial,14"
set xlabel "Time (s)" font "Arial,12"
set ylabel "Avg Latency (us)" font "Arial,12"
set grid
set key top left
set datafile separator ","
# Convert time us->s
plot '$csv_file' every ::1 using (\$1/1e6):2 with lines linewidth 2 linecolor rgb "green" title "Avg Read Latency"

# Bottom plot: Hit rate over time
set title "Hit Rate" font "Arial,14"
set xlabel "Time (s)" font "Arial,12"
set ylabel "Hit Rate" font "Arial,12"
set yrange [0:1.1]
plot '$csv_file' every ::1 using (\$1/1e6):3 with lines linewidth 2 linecolor rgb "orange" title "Hit Rate"

unset multiplot
EOF

    echo "  Saved to $png_file"
}

# Function to plot combined lag and reads for a scenario
plot_combined_scenario() {
    local scenario_name="$1"
    local lag_file="$RESULTS_DIR/${scenario_name}_lag.csv"
    local reads_file="$RESULTS_DIR/${scenario_name}_reads.csv"
    local png_file="$PLOTS_DIR/${scenario_name}_combined.png"

    if [ ! -f "$lag_file" ]; then
        return
    fi

    echo "Creating combined plot for $scenario_name..."

    if [ -f "$reads_file" ]; then
        # Both lag and reads available
        gnuplot <<EOF
set terminal png size 1400,900 font "Arial,12"
set output '$png_file'

set multiplot layout 2,1 title "Benchmark Results - $scenario_name" font "Arial,16"

# Top plot: Replication lag
set title "Replication Lag" font "Arial,14"
set xlabel "Time (s)" font "Arial,12"
set ylabel "Lag (ms)" font "Arial,12"
set grid
set key top left
set datafile separator ","
# Convert: time us->s, lag us->ms
plot '$lag_file' every ::1 using (\$1/1e6):(\$2/1000) with lines linewidth 2 linecolor rgb "blue" title "Replication Lag"

# Bottom plot: Read latency
set title "Read Latency" font "Arial,14"
set xlabel "Time (s)" font "Arial,12"
set ylabel "Latency (us)" font "Arial,12"
set autoscale y
# Convert time us->s
plot '$reads_file' every ::1 using (\$1/1e6):2 with lines linewidth 2 linecolor rgb "green" title "Avg Read Latency"

unset multiplot
EOF
    else
        # Only lag available
        gnuplot <<EOF
set terminal png size 1200,800 font "Arial,12"
set output '$png_file'

set title "Replication Lag - $scenario_name" font "Arial,16"
set xlabel "Time (s)" font "Arial,14"
set ylabel "Lag (ms)" font "Arial,14"

set grid
set key top left

set datafile separator ","

# Convert: time us->s, lag us->ms
plot '$lag_file' every ::1 using (\$1/1e6):(\$2/1000) with lines linewidth 2 linecolor rgb "blue" title "Replication Lag"
EOF
    fi

    echo "  Saved to $png_file"
}

# Function to print summary from CSV
print_summary() {
    local scenario_name="$1"
    local summary_file="$RESULTS_DIR/${scenario_name}_summary.csv"

    if [ -f "$summary_file" ]; then
        echo ""
        echo "  Summary for $scenario_name:"
        tail -n +2 "$summary_file" | while IFS=, read -r metric value; do
            printf "    %-20s %s\n" "$metric:" "$value"
        done
    fi
}

# Extract unique scenario names from files
get_scenario_names() {
    ls "$RESULTS_DIR"/*_lag.csv 2>/dev/null | xargs -n 1 basename 2>/dev/null | sed 's/_lag\.csv$//' | sort -u
}

# Main execution
if [ $# -eq 1 ]; then
    # Plot specific scenario
    scenario="$1"
    lag_file="$RESULTS_DIR/${scenario}_lag.csv"

    if [ ! -f "$lag_file" ]; then
        echo "Error: Results file not found: $lag_file"
        echo "Available scenarios:"
        get_scenario_names | sed 's/^/  - /'
        exit 1
    fi

    plot_lag "$lag_file"

    reads_file="$RESULTS_DIR/${scenario}_reads.csv"
    if [ -f "$reads_file" ]; then
        plot_reads "$reads_file"
    fi

    plot_combined_scenario "$scenario"
    print_summary "$scenario"
else
    # Plot all scenarios
    scenario_names=$(get_scenario_names)

    if [ -z "$scenario_names" ]; then
        echo "No result files found in $RESULTS_DIR/"
        echo "Run the benchmark first:"
        echo "  mix benchmark"
        exit 1
    fi

    echo "=== Generating plots for all scenarios ==="
    echo ""

    # Plot individual scenarios
    for scenario in $scenario_names; do
        lag_file="$RESULTS_DIR/${scenario}_lag.csv"
        if [ -f "$lag_file" ]; then
            plot_lag "$lag_file"
        fi

        reads_file="$RESULTS_DIR/${scenario}_reads.csv"
        if [ -f "$reads_file" ]; then
            plot_reads "$reads_file"
        fi

        plot_combined_scenario "$scenario"
        print_summary "$scenario"
        echo ""
    done
fi

echo ""
echo "=== All plots generated ==="
echo "Plots saved to $PLOTS_DIR/"
echo ""
echo "View plots:"
ls "$PLOTS_DIR"/*.png 2>/dev/null | sed 's/^/  /'
