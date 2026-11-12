# One pass over <package-dir>/{src,ext} as CLI would do; prints finding count.
# Usage: julia --project=spikes/s4-syntax-matcher spikes/s4-syntax-matcher/bench/oneshot.jl <package-dir>
include(joinpath(@__DIR__, "..", "src", "S4Matcher.jl"))
include(joinpath(@__DIR__, "..", "src", "rules.jl"))

files = [joinpath(r, f) for d in ("src", "ext") if isdir(joinpath(ARGS[1], d)) for (r, _, fs) in walkdir(joinpath(ARGS[1], d)) for f in fs if endswith(f, ".jl")]
rules = vcat(footgun_rules(), lintapp_shaped_rules())
println(sum(length(run_rules(rules, f, s, parse_file(s))) for f in files for s in (read(f, String),)))
