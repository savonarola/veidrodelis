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