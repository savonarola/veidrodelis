#!/bin/bash

set -xe

name=$(cargo metadata --no-deps | jq '.packages[0].name' -r)
mix_root="../.."

echo "Calculating coverage for $name"

cd "$mix_root" && MIX_ENV=test mix compile
cd -

source <(cargo llvm-cov show-env --export-prefix)
cargo llvm-cov clean --workspace
cargo build --profile test
cp target/debug/*.so "${mix_root}/priv/native/${name}.so"

cd "$mix_root" && mix test # --include slow
cd -

cargo llvm-cov report --html

rm -rf "${mix_root}/cover/${name}"
cp -r target/llvm-cov/html "${mix_root}/cover/${name}"

