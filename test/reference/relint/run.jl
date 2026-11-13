# Run every ReLint rule on given paths; write rule names and reports as JSON.
# Usage: julia --project=test/reference/relint test/reference/relint/run.jl <out.json> <path>...
using JSON3: JSON3
using ReLint: ReLint

"""Julia files at or under `path`, sorted."""
julia_files(path::String)::Vector{String} =
    isfile(path) ? [path] : sort!([joinpath(root, name) for (root, _, names) in walkdir(path) for name in names if endswith(name, ".jl")])

"""Records `(file, line, rule)` ReLint reports for `path`, linted from copy under `scratch`."""
function lint(path::String, scratch::String)::Vector{@NamedTuple{file::String, line::Int, rule::String}}
    return mktempdir(scratch) do directory
        # Copy under `src/Compiler`: ReLint scopes some rules there; path without `test/` keeps test exemptions off.
        copy = joinpath(directory, "src", "Compiler", basename(path))
        mkpath(dirname(copy))
        cp(path, copy)
        context = ReLint.LintContext()
        return [
            (; file = isfile(path) ? abspath(path) : joinpath(abspath(path), relpath(file, copy)), line = report.line, rule = report.rule.name)
                for file in julia_files(copy) for report in ReLint.lint_file(file, context)
        ]
    end
end

"""Write every ReLint rule name, and reports on `paths`, to `out`."""
function main(out::String, paths::Vector{String})::Nothing
    reports = reduce(vcat, (lint(path, dirname(abspath(out))) for path in paths))
    write(out, JSON3.write((; rules = sort!(unique([rule.name for rule in ReLint.ALL_RULES])), reports)))
    return nothing
end

main(ARGS[1], ARGS[2:end])
