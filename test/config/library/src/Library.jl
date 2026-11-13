"""Fixture package for config and level tests."""
module Library
# `a.jl` compares `total`; load must not throw.
total = 1.0
include("../a.jl")
end
