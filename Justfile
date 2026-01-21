HOST := `hostname`

format:
    mix format

# Run tests excluding slow tests (reconnection and ack tests)
test:
    mix test --trace

# Run all tests including slow tests
test-all:
    mix test --trace --include slow

compile:
    mix compile

# Run tests with coverage report (HTML)
cov:
    mix coveralls.html # --include slow
    cd native/vdr_ts_nif && ./cover.sh
    cd native/vdr_redis_nif && ./cover.sh
    @echo "Coverage report: http://{{HOST}}:8000"
    @cd cover && python3 -m http.server 8000 > /dev/null

cov-ex:
    mix coveralls.html --include slow
    @echo "Coverage report: http://{{HOST}}:8000"
    @cd cover && python3 -m http.server 8000 > /dev/null

clean:
    rm -rf native/vdr_redis_nif/target/*
    rm -rf priv/native/*
    rm -f *.profraw
    sudo rm -rf benchmark/plots/*_perf.data.old
    sudo rm -rf benchmark/plots/*_perf.data
    mix clean

clean-all: clean
    mix clean --deps

# Start Redis in Docker for testing
dc-start:
    cd test/assets && docker compose up -d

# Stop Redis Docker container
dc-stop:
    cd test/assets && docker compose down

dc-restart:
    cd test/assets && docker compose down -v && docker compose up -d

# Stop Redis and remove volumes
dc-clean:
    cd test/assets && docker compose down -v

dc-logs:
    cd test/assets && docker compose logs -f

# List available benchmark scenarios
bench-list:
    mix benchmark --list

default_scenario := 'hashes_50k'
duration := '30'
intensity := '50000'
readers := '1'

# Run benchmark with profiling and generate flamegraphs
# Requires: sudo access for perf, perf tools installed
bench-profile scenario=default_scenario:
    ./scripts/bench-profile.sh {{scenario}} {{duration}} {{intensity}} {{readers}}
    @echo "View plots at: http://{{HOST}}:8000"
    python3 -m http.server 8000 -d benchmark/plots/
