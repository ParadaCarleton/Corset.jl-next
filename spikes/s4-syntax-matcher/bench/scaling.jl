# Match time versus rule count: replicate five rules k times on DataStructures src/.
# Usage: julia --project=spikes/s4-syntax-matcher spikes/s4-syntax-matcher/bench/scaling.jl
include(joinpath(@__DIR__, "..", "src", "S4Matcher.jl"))
include(joinpath(@__DIR__, "..", "src", "rules.jl"))
import DataStructures

root = joinpath(pkgdir(DataStructures), "src")
sources = [f => read(f, String) for (r, _, fs) in walkdir(root) for f in joinpath.(r, fs) if endswith(f, ".jl")]
lines = sum(count(==('\n'), s) for (_, s) in sources)
trees = [parse_file(s) for (_, s) in sources]
for k in (1, 4, 10, 20)
    rules = reduce(vcat, [footgun_rules() for _ in 1:k])
    seconds = minimum(
        @elapsed(
            for ((f, s), t) in zip(sources, trees)
                run_rules(rules, f, s, t)
            end
        ) for _ in 1:10
    )
    println("rules=", length(rules), " match per10k=", round(seconds * 1.0e4 / lines * 1.0e3; digits = 1), "ms")
end
