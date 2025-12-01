#!/bin/bash
# Check prerequisites for running benchmarks

echo "=== Checking Prerequisites for Veidrodelis Benchmarks ==="
echo ""

all_good=true

# Check Elixir
echo -n "Checking Elixir... "
if command -v elixir &> /dev/null; then
    version=$(elixir --version | grep Elixir | awk '{print $2}')
    echo "✓ Found version $version"
else
    echo "✗ Not found"
    echo "  Install from: https://elixir-lang.org/install.html"
    all_good=false
fi

# Check Mix
echo -n "Checking Mix... "
if command -v mix &> /dev/null; then
    echo "✓ Found"
else
    echo "✗ Not found"
    all_good=false
fi

# Check Redis server
echo -n "Checking Redis... "
if command -v redis-server &> /dev/null; then
    version=$(redis-server --version | awk '{print $3}' | cut -d= -f2)
    echo "✓ Found version $version"
else
    echo "✗ Not found"
    echo "  Install from: https://redis.io/download"
    all_good=false
fi

# Check if Redis is running
echo -n "Checking Redis connection (localhost:6379)... "
if command -v redis-cli &> /dev/null; then
    if redis-cli -h localhost -p 6379 ping &> /dev/null; then
        echo "✓ Connected"
    else
        echo "✗ Cannot connect"
        echo "  Start Redis with: redis-server --port 6379"
        all_good=false
    fi
else
    echo "⚠ Cannot test (redis-cli not found)"
fi

# Check gnuplot (optional)
echo -n "Checking gnuplot (optional)... "
if command -v gnuplot &> /dev/null; then
    version=$(gnuplot --version | awk '{print $2}')
    echo "✓ Found version $version"
else
    echo "⚠ Not found (plots will not be generated)"
    echo "  Install from your package manager:"
    echo "    Ubuntu/Debian: sudo apt-get install gnuplot"
    echo "    macOS: brew install gnuplot"
    echo "    Fedora: sudo dnf install gnuplot"
fi

# Check if dependencies are compiled
echo -n "Checking project dependencies... "
if [ -d "../_build/dev/lib/veidrodelis" ] && [ -d "../_build/dev/lib/redix" ]; then
    echo "✓ Compiled"
else
    echo "✗ Not compiled"
    echo "  Run from project root: mix deps.get && mix compile"
    all_good=false
fi

echo ""
if [ "$all_good" = true ]; then
    echo "=== All Prerequisites Met ==="
    echo ""
    echo "Ready to run benchmarks!"
    echo "  cd benchmark"
    echo "  mix run run_benchmarks.exs"
    exit 0
else
    echo "=== Some Prerequisites Missing ==="
    echo ""
    echo "Please fix the issues above before running benchmarks."
    exit 1
fi
