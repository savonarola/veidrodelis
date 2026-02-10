#!/bin/bash

set -xe

export MIX_ENV=test
# enable trace logging to get full coverage
export RUST_LOG=trace

if [ "$1" == "slow" ]; then
    SLOW_TAG="--include slow"
else
    SLOW_TAG=""
fi

source <(cargo llvm-cov show-env --export-prefix)
cargo llvm-cov clean --workspace

mix compile

rm -rf cover/nif cover/elixir
mkdir -p cover/nif
mkdir -p cover/elixir

mix coveralls.multiple --type lcov --type html -o cover/elixir $SLOW_TAG

cargo llvm-cov report --html --output-dir cover/nif
cargo llvm-cov report --lcov > cover/nif/lcov.info
