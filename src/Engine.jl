"""Discover files, build facts, run registered rules; apply opt-outs, levels, confidence setting and baseline."""
module Engine

using ..Facts: FactSet, Finding, BlindSpot, RuleEntry, Confidence
using ..Rules: REGISTRY, entry
using ..Config: Config, Flags, Settings, Level, level_of, project_root
using ..OptOuts: OptOuts
using ..Fixes: Fixes
using ..Baseline: Baseline
using ..Discovery: Discovery
using ..Syntax: Syntax

"""Finding with level from settings. `source` says where level was set."""
struct Diagnostic
    finding::Finding
    level::Level.T
    source::String
end

"""Result of one run: diagnostics, settings, project root, source text per file, baselined count, stale baseline keys and blind spots."""
struct Report
    diagnostics::Vector{Diagnostic}
    settings::Settings
    root::String
    sources::Dict{String, String}
    baselined::Int
    stale::Vector{Baseline.Key}
    blind_spots::Vector{BlindSpot}
end

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
    blind_spots::Vector{BlindSpot}
end

"""Analyze files `Discovery.discover` picks for `path`, with config of enclosing project and command-line `flags`. Opt-outs apply before levels."""
function analyze(path::String, flags::Flags)::Analysis
    project = project_root(path)
    settings = Config.settings(project, flags, REGISTRY)
    sources = Discovery.discover(path)
    facts = FactSet(sources.files, sources.entries)
    kept, problems = OptOuts.apply(facts, run_rules(facts), Set(rule.name for rule in REGISTRY))
    leveled = diagnostics(kept, settings)
    root = something(project, isdir(path) ? abspath(path) : dirname(abspath(path)))
    keys = Baseline.finding_keys(facts, root, [diagnostic.finding for diagnostic in leveled])
    checks = [
        [Diagnostic(problem, Level.deny, Syntax.PARSE_SOURCE) for problem in Syntax.parse_problems(facts)];
        [Diagnostic(problem, Level.deny, OptOuts.SOURCE) for problem in problems]
    ]
    return Analysis(settings, facts, root, leveled, keys, checks, sources.blind_spots)
end

"""Report for files discovered from `path`; baseline at project root hides known findings."""
function check(path::String; flags::Flags = Flags())::Report
    analysis = analyze(path, flags)
    covered, stale = Baseline.cover(Baseline.read_baseline(analysis.root), analysis.keys)
    reported = [analysis.leveled[.!covered]; analysis.problems]
    sort!(reported; by = diagnostic -> (diagnostic.finding.primary.span.file, diagnostic.finding.primary.span.first_byte, diagnostic.finding.rule))
    sources = Dict(file.path => file.text for file in analysis.facts.files)
    return Report(reported, analysis.settings, analysis.root, sources, count(covered), stale, analysis.blind_spots)
end

"""Write baseline at project root of `path` from every reported finding; return entry count."""
function baseline(path::String; flags::Flags = Flags())::Int
    analysis = analyze(path, flags)
    Baseline.write_baseline(analysis.root, analysis.keys)
    return length(analysis.keys)
end

"""Apply fixes of reported findings under `path` up to fix tier; return number of edits applied."""
function fix!(path::String; flags::Flags = Flags())::Int
    report = check(path; flags)
    findings = [diagnostic.finding for diagnostic in report.diagnostics]
    applied = 0
    for (file, text) in report.sources
        edits = Fixes.applicable_edits(findings, file, report.settings.tier)
        isempty(edits) && continue
        write(file, Fixes.apply_edits(text, edits))
        applied += length(edits)
    end
    return applied
end

end
