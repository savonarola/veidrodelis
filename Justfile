format:
    mix format

# Run tests excluding slow tests (reconnection and ack tests)
test:
    mix test --trace

# Run all tests including slow tests
test-all:
    mix test --trace --include slow

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

default_bm_scenario := 'hashes_100k'

# Run benchmarks
bench scenario=default_bm_scenario:
    rm -f benchmark/results/*.csv
    rm -f benchmark/plots/*.png
    mix benchmark {{scenario}}
    cd benchmark && ./plot.sh
    python3 -m http.server 8000 -d benchmark/plots/