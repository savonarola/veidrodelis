#!/bin/bash

set -xe

export MIX_ENV=test

source <(cargo llvm-cov show-env --export-prefix)
cargo llvm-cov clean --workspace

mix compile

rm -rf cover/nif cover/elixir
mkdir -p cover/nif
mkdir -p cover/elixir

mix coveralls.multiple --type lcov --type html -o cover/elixir --include slow

cargo llvm-cov report --html --output-dir cover/nif
cargo llvm-cov report --lcov > cover/nif/lcov.info
