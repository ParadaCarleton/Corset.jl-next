# Write `symbols.txt`: MPFR and GMP C functions that Base (running Julia version) and SpecialFunctions call.
# Run: julia --project=gen/foreign gen/foreign/scan.jl
using SpecialFunctions: SpecialFunctions
include("calls.jl")

names = Set(first.(module_calls((Base.MPFR, Base.GMP, Base.GMP.MPZ, Base.GMP.MPQ, SpecialFunctions))))
# Extra functions: no Base or SpecialFunctions call, but other numeric packages call them.
const EXTRA = [:mpfr_get_d, :mpfr_cmp, :mpfr_swap, :mpfr_remquo, :mpfr_strtofr]
mine = sort!(union(filter(name -> startswith(string(name), r"mpfr_|__gmp"), collect(names)), EXTRA))
write(joinpath(@__DIR__, "symbols.txt"), join(mine, "\n"), "\n")
println(length(mine), " symbols; Julia ", VERSION)
