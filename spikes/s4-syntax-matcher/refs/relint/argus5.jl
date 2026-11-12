# Same five footguns written as Argus patterns; time Argus on corpus for apples-to-apples speed.
# Usage: julia --project=refs/relint refs/relint/argus5.jl <corpus-dir>...
using ReLint, Argus

julia_files(dir::String)::Vector{String} = !isdir(dir) ? String[] : sort!([joinpath(root, f) for (root, _, fs) in walkdir(dir) for f in fs if endswith(f, ".jl")])

const RULES = [
    Argus.Rule("F10", "approx zero", @pattern ~or({x} ≈ 0, 0 ≈ {x}, {x} ≈ 0.0, 0.0 ≈ {x}, isapprox({x}, 0), isapprox(0, {x}), isapprox({x}, 0.0), isapprox(0.0, {x}))),
    Argus.Rule("F21", "empty literal", @pattern ~or([], Dict(), Set(), IdDict(), Vector(), Any[])),
    Argus.Rule("F35", "fill shared", @pattern ~or(fill(zeros({_}...), {_}...), fill(ones({_}...), {_}...), fill(similar({_}...), {_}...), fill(Dict({_}...), {_}...), fill(Set({_}...), {_}...), fill(Ref({_}...), {_}...), fill(copy({_}...), {_}...), fill(randn({_}...), {_}...), fill([{_}...], {_}...))),
    Argus.Rule("F36", "one to length", @pattern ~or(1:length({a}), 1:size({a}, {_}), 1:lastindex({a}))),
    Argus.Rule("F68", "threadid", @pattern ~or({_}[threadid()], {_}[Threads.threadid()])),
]

function main(dirs::Vector{String})::Nothing
    context = ReLint.LintContext(RULES)
    for dir in dirs
        files = [f for d in ("src", "ext") for f in julia_files(joinpath(dir, d))]
        lines = sum(count(==('\n'), read(f, String)) for f in files)
        cold = @elapsed foreach(f -> ReLint.lint_file(f, context), files)
        warm = minimum(@elapsed(foreach(f -> ReLint.lint_file(f, context), files)) for _ in 1:5)
        println(basename(dir), " lines=", lines, " cold=", round(cold; digits = 2), "s warm=", round(warm; digits = 3), "s per10k=", round(warm * 1.0e4 / lines; digits = 3), "s")
        for f in files, r in ReLint.lint_file(f, context)
            println("  ", r.rule.name, " ", relpath(f, dir), ":", r.line)
        end
    end
    return nothing
end

main(ARGS)
