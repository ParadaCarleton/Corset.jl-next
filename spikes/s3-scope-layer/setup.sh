#!/usr/bin/env bash
# Vendor JuliaLowering and JuliaSyntax from last julia commit that loads on Julia 1.13.
set -euo pipefail
cd "$(dirname "$0")"
pin=f0188d597b35600751a8e3c7b08ac9a4f02103a1  # parent of 8597967694 (moves Syntax into Base, needs 1.14)
mkdir -p vendor
[ -d vendor/julia ] || git clone --filter=blob:none --no-checkout https://github.com/JuliaLang/julia.git vendor/julia
git -C vendor/julia sparse-checkout set --cone JuliaLowering JuliaSyntax
git -C vendor/julia fetch --depth 1 --filter=blob:none origin "$pin"
git -C vendor/julia checkout -q "$pin"
JULIA_LOAD_PATH="@:@stdlib" JULIA_PROJECT="$PWD" julia +1.13 --startup-file=no -e 'using Pkg; Pkg.instantiate()'
