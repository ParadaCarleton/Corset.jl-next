"""Collect files, build facts, run registered rules, apply levels and confidence setting."""
module Engine

using ..Facts: FactSet, Finding, RuleEntry, Confidence
using ..Syntax: parse_file
using ..Rules: REGISTRY, entry
using ..Config: Config, Flags, Settings, Level, level_of, project_root

"""Finding with level from settings. `source` says where level was set."""
struct Diagnostic
    finding::Finding
    level::Level.T
    source::String
end

"""Result of one run: reported diagnostics, settings that produced them, and source text per file."""
struct Report
    diagnostics::Vector{Diagnostic}
    settings::Settings
    sources::Dict{String, String}
end

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

"""Diagnostics for `findings` under `settings`: drops `allow` findings and findings below confidence setting."""
function diagnostics(findings::Vector{Finding}, settings::Settings)::Vector{Diagnostic}
    reported = Diagnostic[]
    for finding in findings
        settings.confidence == Confidence.definite && finding.confidence == Confidence.possible && continue
        level, source = level_of(settings, entry(finding.rule))
        level == Level.allow || push!(reported, Diagnostic(finding, level, source))
    end
    return reported
end

"""Whether `report` fails run: any `deny` diagnostic, or any `warn` diagnostic under `--deny warnings`."""
failed(report::Report)::Bool = any(report.diagnostics) do diagnostic
    diagnostic.level == Level.deny || (report.settings.deny_warnings && diagnostic.level == Level.warn)
end

"""Report for every Julia file under `path`, with config of enclosing project and command-line `flags`."""
function check(path::String; flags::Flags = Flags())::Report
    settings = Config.settings(project_root(path), flags, REGISTRY)
    facts = facts_for(julia_files(path))
    return Report(diagnostics(run_rules(facts), settings), settings, Dict(file.path => file.text for file in facts.files))
end

end
