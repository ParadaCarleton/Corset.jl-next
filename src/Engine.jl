"""Collect files, build facts, run registered rules."""
module Engine

using ..Facts: FactSet, Finding, RuleEntry
using ..Syntax: parse_file
using ..Rules: REGISTRY

"""Julia files under `path` in sorted order; `path` itself when it is a file."""
function julia_files(path::String)::Vector{String}
    isfile(path) && return [path]
    isdir(path) || throw(ArgumentError("no such file or directory: $path"))
    return sort!([joinpath(root, name) for (root, _, names) in walkdir(path) for name in names if endswith(name, ".jl")])
end

"""Facts for files `paths`, each file read and parsed once."""
facts_for(paths::Vector{String})::FactSet = FactSet([parse_file(path, read(path, String)) for path in paths])

"""Findings of `rules` on `facts`, sorted by file and position."""
function run_rules(facts::FactSet, rules::Vector{RuleEntry} = REGISTRY)::Vector{Finding}
    findings = reduce(vcat, (entry.run(facts) for entry in rules); init = Finding[])
    return sort!(findings; by = finding -> (finding.primary.span.file, finding.primary.span.first_byte, finding.rule))
end

"""Findings of registered rules on every Julia file under `path`."""
check(path::String; rules::Vector{RuleEntry} = REGISTRY)::Vector{Finding} = run_rules(facts_for(julia_files(path)), rules)

end
