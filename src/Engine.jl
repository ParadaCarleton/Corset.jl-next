"""Collect files, build facts, run registered rules; apply opt-outs, levels, confidence setting and baseline."""
module Engine

using ..Facts: FactSet, Finding, RuleEntry, Confidence
using ..Syntax: parse_file
using ..Rules: REGISTRY, entry
using ..Config: Config, Flags, Settings, Level, level_of, project_root
using ..OptOuts: OptOuts
using ..Baseline: Baseline

"""Finding with level from settings. `source` says where level was set."""
struct Diagnostic
    finding::Finding
    level::Level.T
    source::String
end

"""Result of one run: reported diagnostics, settings, source text per file, baselined count and stale baseline keys."""
struct Report
    diagnostics::Vector{Diagnostic}
    settings::Settings
    sources::Dict{String, String}
    baselined::Int
    stale::Vector{Baseline.Key}
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

"""Whether `report` fails run: stale baseline entry, any `deny` diagnostic, or any `warn` diagnostic under `--deny warnings`."""
failed(report::Report)::Bool = !isempty(report.stale) || any(report.diagnostics) do diagnostic
    diagnostic.level == Level.deny || (report.settings.deny_warnings && diagnostic.level == Level.warn)
end

"""One analysis of `path`: settings, facts, baseline root, leveled diagnostics with their baseline keys, and opt-out problems."""
struct Analysis
    settings::Settings
    facts::FactSet
    root::String
    leveled::Vector{Diagnostic}
    keys::Vector{Baseline.Key}
    problems::Vector{Diagnostic}
end

"""Analyze every Julia file under `path` with config of enclosing project and command-line `flags`. Opt-outs apply before levels."""
function analyze(path::String, flags::Flags)::Analysis
    project = project_root(path)
    settings = Config.settings(project, flags, REGISTRY)
    facts = facts_for(julia_files(path))
    kept, problems = OptOuts.apply(facts, run_rules(facts), Set(rule.name for rule in REGISTRY))
    leveled = diagnostics(kept, settings)
    root = something(project, isdir(path) ? abspath(path) : dirname(abspath(path)))
    files = Dict(file.path => file for file in facts.files)
    keys = [Baseline.key(files[diagnostic.finding.primary.span.file], root, diagnostic.finding) for diagnostic in leveled]
    return Analysis(settings, facts, root, leveled, keys, [Diagnostic(problem, Level.deny, OptOuts.SOURCE) for problem in problems])
end

"""Report for every Julia file under `path`; baseline at project root hides known findings."""
function check(path::String; flags::Flags = Flags())::Report
    analysis = analyze(path, flags)
    covered, stale = Baseline.cover(Baseline.read_baseline(analysis.root), analysis.keys)
    reported = [analysis.leveled[.!covered]; analysis.problems]
    sort!(reported; by = diagnostic -> (diagnostic.finding.primary.span.file, diagnostic.finding.primary.span.first_byte, diagnostic.finding.rule))
    sources = Dict(file.path => file.text for file in analysis.facts.files)
    return Report(reported, analysis.settings, sources, count(covered), stale)
end

"""Write baseline at project root of `path` from every reported finding; return entry count."""
function baseline(path::String; flags::Flags = Flags())::Int
    analysis = analyze(path, flags)
    Baseline.write_baseline(analysis.root, analysis.keys)
    return length(analysis.keys)
end

end
