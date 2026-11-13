# Run LintApp with every rule on given paths; write reports as JSON.
# Usage: julia --project=test/reference/lintapp test/reference/lintapp/run.jl <out.json> <path>...
# LintApp lints only files inside project, so each path is copied into temporary project next to output.
using JSON: JSON
using LintApp: LintApp

"""Project settings: nameless project, all rules on through `strict` preset."""
const PROJECT = "[deps]\n"
const CONFIG = "preset = \"strict\"\n\n[rules]\nsyntax_warnings = \"warning\"\nmissing_reference = { severity = \"warning\", scope = \"all\" }\n"

"""Records `(file, line, rule, message)` LintApp reports for `path`; files named by their place under `path`."""
function lint(path::String, scratch::String)::Vector{Dict{String, Any}}
    return mktempdir(scratch) do project
        corpus = joinpath(project, "corpus")
        isfile(path) ? (mkpath(corpus); cp(path, joinpath(corpus, basename(path)))) : cp(path, corpus)
        write(joinpath(project, "Project.toml"), PROJECT)
        write(joinpath(project, "JuliaLint.toml"), CONFIG)
        out = joinpath(project, "lintapp.json")
        LintApp.main(["--format", "json", "--no-progress", "-o", out, project])
        origin = isfile(path) ? dirname(abspath(path)) : abspath(path)
        return [
            Dict{String, Any}("file" => joinpath(origin, relpath(entry["file"], corpus)), "line" => report["startLine"], "rule" => report["rule"], "message" => report["message"])
                for entry in JSON.parsefile(out) for report in entry["diagnostics"]
        ]
    end
end

"""Write every LintApp rule id, and reports on `paths`, to `out`."""
function main(out::String, paths::Vector{String})::Nothing
    reports = reduce(vcat, (lint(path, dirname(abspath(out))) for path in paths))
    write(out, JSON.json(Dict("rules" => sort!([string(rule.id) for rule in LintApp.JuliaWorkspaces.LINT_RULES]), "reports" => reports)))
    return nothing
end

main(ARGS[1], ARGS[2:end])
