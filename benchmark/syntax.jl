# Time family-A rules per 10,000 lines on package sources: parse and match separately.
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
    matching = best_time(() -> Corset.Engine.run_rules(facts), 5)
    found = length(Corset.Engine.run_rules(facts))
    per10k(seconds) = round(seconds * 1.0e4 / lines * 1000; digits = 1)
    println(
        directory, ": lines=", lines, " parse=", per10k(parse), "ms/10k match=", per10k(matching), "ms/10k rules=",
        length(Corset.Rules.REGISTRY), " findings=", found
    )
end
