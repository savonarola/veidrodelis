format:
    mix format

test:
    mix test --trace

# Start Redis in Docker for testing
redis-start:
    cd test/assets && docker compose up -d

# Stop Redis Docker container
redis-stop:
    cd test/assets && docker compose down

# Stop Redis and remove volumes
redis-clean:
    cd test/assets && docker compose down -v