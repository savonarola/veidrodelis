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
    sudo rm -rf benchmark/plots/*.data.old
    sudo rm -rf benchmark/plots/*.data benchmark/plots/*.folded benchmark/plots/*.txt
    mix clean

clean-all: clean
    mix clean --deps

# Start Redis in Docker for testing
dc-start:
    cd test/assets && docker compose up -d

# Stop Redis Docker container
dc-stop:
    cd test/assets && docker compose down --remove-orphans

dc-restart:
    cd test/assets && docker compose down -v --remove-orphans && docker compose up -d

# Stop Redis and remove volumes
dc-clean:
    cd test/assets && docker compose down -v --remove-orphans

dc-logs:
    cd test/assets && docker compose logs -f

# Start Sentinel services in Docker for testing
dc-sentinel-start:
    cd test/assets && docker compose -f docker-compose-sentinel.yml up -d

# Stop Sentinel Docker services
dc-sentinel-stop:
    cd test/assets && docker compose -f docker-compose-sentinel.yml down --remove-orphans

# Restart Sentinel Docker services
dc-sentinel-restart:
    cd test/assets && docker compose -f docker-compose-sentinel.yml down -v --remove-orphans && docker compose -f docker-compose-sentinel.yml up -d

# Stop Sentinel services and remove volumes
dc-sentinel-clean:
    cd test/assets && docker compose -f docker-compose-sentinel.yml down -v --remove-orphans

# View Sentinel service logs
dc-sentinel-logs:
    cd test/assets && docker compose -f docker-compose-sentinel.yml logs -f

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
