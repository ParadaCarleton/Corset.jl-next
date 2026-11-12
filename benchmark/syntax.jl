# Time family-A checks per 10,000 lines on package sources: parse and match separately.
# Usage: julia --project=test benchmark/syntax.jl <src-dir>...
using Corset: Corset

"""Minimum time of `runs` calls of `work`, after one warm-up call."""
function best_time(work::Function, runs::Int)::Float64
    work()
    return minimum(@elapsed(work()) for _ in 1:runs)
end

for directory in ARGS
    paths = Corset.Engine.julia_files(directory)
    lines = sum(path -> count(==('\n'), read(path, String)), paths)
    parse = best_time(() -> Corset.Engine.facts_for(paths), 5)
    facts = Corset.Engine.facts_for(paths)
    check = best_time(() -> Corset.Engine.run_checks(facts), 5)
    found = length(Corset.Engine.run_checks(facts))
    per10k(seconds) = round(seconds * 1.0e4 / lines * 1000; digits = 1)
    println(
        directory, ": lines=", lines, " parse=", per10k(parse), "ms/10k match=", per10k(check), "ms/10k checks=",
        length(Corset.Checks.REGISTRY), " findings=", found
    )
end
