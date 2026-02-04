HOST := `hostname`

format:
    mix format

test:
    mix test --trace

test-all:
    mix test --trace --include slow

compile:
    mix compile

cov:
    mix coveralls.html --include slow
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

dc-start:
    cd test/assets && docker compose up -d

dc-stop:
    cd test/assets && docker compose down -v

dc-restart: dc-stop dc-start

dc-logs:
    cd test/assets && docker compose logs -f

dc-sentinel-start:
    cd test/assets && docker compose -f docker-compose-sentinel.yml up -d

dc-sentinel-stop:
    cd test/assets && docker compose -f docker-compose-sentinel.yml down -v

dc-sentinel-restart: dc-sentinel-stop dc-sentinel-start

dc-sentinel-logs:
    cd test/assets && docker compose -f docker-compose-sentinel.yml logs -f

bench-list:
    mix benchmark --list

default_scenario := 'hashes'
duration := '30'
intensity := '50000'
readers := '1'

# Requires: sudo access for perf, perf tools installed
bench-profile scenario=default_scenario:
    ./scripts/bench-profile.sh {{scenario}} {{duration}} {{intensity}} {{readers}}
    @echo "View plots at: http://{{HOST}}:8000"
    python3 -m http.server 8000 -d benchmark/plots/

bench scenario=default_scenario:
    mix benchmark {{scenario}} --duration {{duration}} --intensity {{intensity}} --readers {{readers}}
