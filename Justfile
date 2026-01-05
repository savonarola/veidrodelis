HOST := `hostname`

format:
    mix format

# Run tests excluding slow tests (reconnection and ack tests)
test:
    mix test --trace

# Run all tests including slow tests
test-all:
    mix test --trace --include slow

# Run tests with coverage report (HTML)
cov-html:
    mix coveralls.html --include slow
    @echo "Coverage report: http://{{HOST}}:8000"
    @cd cover && python3 -m http.server 8000 > /dev/null

# Run tests with detailed coverage in terminal
cov:
    mix coveralls.detail --include slow

clean:
    rm -rf native/vdr_redis_nif/target/*
    rm -rf priv/native/*
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

default_bm_scenario := 'hashes_100k'

# Run benchmarks
bench scenario=default_bm_scenario:
    rm -f benchmark/results/*.csv
    rm -f benchmark/plots/*.png
    mix benchmark {{scenario}}
    cd benchmark && ./plot.sh
    python3 -m http.server 8000 -d benchmark/plots/
