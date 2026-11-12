"""Collect files, build facts, run registered checks."""
module Engine

using ..Facts: FactSet, Finding, CheckEntry
using ..Syntax: parse_file
using ..Checks: REGISTRY

"""Julia files under `path` in sorted order; `path` itself when it is a file."""
function julia_files(path::String)::Vector{String}
    isfile(path) && return [path]
    isdir(path) || throw(ArgumentError("no such file or directory: $path"))
    return sort!([joinpath(root, name) for (root, _, names) in walkdir(path) for name in names if endswith(name, ".jl")])
end

"""Facts for files `paths`, each file read and parsed once."""
facts_for(paths::Vector{String})::FactSet = FactSet([parse_file(path, read(path, String)) for path in paths])

"""Findings of `checks` on `facts`, sorted by file and position."""
function run_checks(facts::FactSet, checks::Vector{CheckEntry} = REGISTRY)::Vector{Finding}
    findings = reduce(vcat, (entry.run(facts) for entry in checks); init = Finding[])
    return sort!(findings; by = finding -> (finding.primary.span.file, finding.primary.span.first_byte, finding.check))
end

"""Findings of registered checks on every Julia file under `path`."""
check(path::String; checks::Vector{CheckEntry} = REGISTRY)::Vector{Finding} = run_checks(facts_for(julia_files(path)), checks)

end
