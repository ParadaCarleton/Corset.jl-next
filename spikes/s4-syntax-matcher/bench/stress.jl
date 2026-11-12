# Throughput and crash check: matcher over src/ of newest version of every package in depot.
# Usage: julia --project=spikes/s4-syntax-matcher spikes/s4-syntax-matcher/bench/stress.jl
include(joinpath(@__DIR__, "..", "src", "S4Matcher.jl"))
include(joinpath(@__DIR__, "..", "src", "rules.jl"))

function main()::Nothing
    depot = joinpath(first(DEPOT_PATH), "packages")
    roots = [joinpath(depot, p, last(sort(readdir(joinpath(depot, p)); by = v -> mtime(joinpath(depot, p, v))))) for p in readdir(depot) if isdir(joinpath(depot, p)) && !isempty(readdir(joinpath(depot, p)))]
    files = [joinpath(r, f) for root in roots if isdir(joinpath(root, "src")) for (r, _, fs) in walkdir(joinpath(root, "src")) for f in fs if endswith(f, ".jl")]
    sources = [f => read(f, String) for f in files]
    lines = sum(count(==('\n'), s) for (_, s) in sources)
    rules = vcat(footgun_rules(), lintapp_shaped_rules())
    run_rules(rules, "warmup.jl", "x ≈ 0", parse_file("x ≈ 0"))
    counts = Dict{Int, Int}()
    failures = String[]
    samples = String[]
    parse_s = match_s = 0.0
    for (f, s) in sources
        try
            t0 = time_ns(); tree = parse_file(s); t1 = time_ns()
            for x in run_rules(rules, f, s, tree)
                counts[x.footgun] = get(counts, x.footgun, 0) + 1
                x.footgun in (10, 35, 68) && push!(samples, "F$(x.footgun) $(x.file):$(x.line)  $(first(x.text, 80))")
            end
            parse_s += (time_ns() - t0) / 1e9 - (time_ns() - t1) / 1e9
            match_s += (time_ns() - t1) / 1e9
        catch err
            push!(failures, "$f: $(sprint(showerror, err)[1:min(end, 200)])")
        end
    end
    println("packages=", length(roots), " files=", length(files), " lines=", lines, " parse=", round(parse_s; digits = 2), "s match=", round(match_s; digits = 2),
        "s per10k=", round((parse_s + match_s) * 1e4 / lines * 1e3; digits = 1), "ms failures=", length(failures))
    println("findings by footgun: ", sort(collect(counts)))
    foreach(println, first(failures, 10))
    foreach(println, samples)
    return nothing
end

main()
