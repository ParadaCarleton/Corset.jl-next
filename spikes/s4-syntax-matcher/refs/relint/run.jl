# Run ReLint (all rules) on corpus src/ files; print matches and time per 10k lines.
# Usage: julia --project=refs/relint refs/relint/run.jl <corpus-dir>...
using ReLint

julia_files(dir::String)::Vector{String} = sort!([joinpath(root, f) for (root, _, fs) in walkdir(dir) for f in fs if endswith(f, ".jl")])

function main(dirs::Vector{String})::Nothing
    context = ReLint.LintContext()
    for dir in dirs
        files = julia_files(joinpath(dir, "src"))
        lines = sum(count(==('\n'), read(f, String)) for f in files)
        cold = @elapsed foreach(f -> ReLint.lint_file(f, context), files)
        warm = minimum(@elapsed(foreach(f -> ReLint.lint_file(f, context), files)) for _ in 1:3)
        println(basename(dir), " lines=", lines, " cold=", round(cold; digits = 2), "s warm=", round(warm; digits = 3), "s per10k=", round(warm * 1e4 / lines; digits = 3), "s")
        for f in files, r in ReLint.lint_file(f, context)
            println("  ", r.rule.name, " ", relpath(f, dir), ":", r.line, "  ", r.rule.description[1:min(end, 50)])
        end
    end
    return nothing
end

main(ARGS)
