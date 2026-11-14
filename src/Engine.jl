"""Discover files, build facts, run registered rules; apply opt-outs, levels, confidence setting and baseline."""
module Engine

using ..Facts: Facts, FactSet, Finding, BlindSpot, RuleEntry, Confidence, Stage, ProjectFacts, PackageFacts, ExternalFacts
using ..Rules: REGISTRY, entry
using ..Config: Config, Flags, Settings, Level, level_of, project_root
using ..OptOuts: OptOuts
using ..Fixes: Fixes
using ..Baseline: Baseline
using ..Discovery: Discovery
using ..Syntax: Syntax
using ..Package: Package
using ..External: External

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

"""Whether `settings` enable rule `entry`: its level is not `allow`."""
enabled(settings::Settings, entry::RuleEntry)::Bool = first(level_of(settings, entry)) != Level.allow

"""Whether `settings` enable any rule that reads stage after `syntax`."""
needs_package(settings::Settings)::Bool = any(entry -> entry.stage != Stage.syntax && enabled(settings, entry), REGISTRY)

"""Whether run under `settings` loads package of `project`: package project, and enabled rule after `syntax` stage."""
loads(project::Union{Nothing, ProjectFacts}, settings::Settings)::Bool = !isnothing(project) && needs_package(settings)

"""
Loaded package of `project` with method sites in `files`, and its load errors and blind spots.
Nothing loads outside package project, and when no enabled rule reads package.
"""
function load_package(project::Union{Nothing, ProjectFacts}, settings::Settings, files::Vector{Facts.SyntaxFile})::Package.Loaded
    return loads(project, settings) ? Package.load(project, files) : Package.Loaded(nothing, Finding[], BlindSpot[])
end

"""External facts of loaded `package` with analyzed `files` when `settings` enable `external` rule; `nothing` otherwise."""
function external_facts(package::Union{Nothing, PackageFacts}, files::Vector{Facts.SyntaxFile}, settings::Settings)::Union{Nothing, ExternalFacts}
    wanted = any(entry -> entry.stage == Stage.external && enabled(settings, entry), REGISTRY)
    return isnothing(package) || !wanted ? nothing : External.external_facts(package, files)
end

"""Project facts of package run on `path` with `flags` loads; `nothing` when run loads no package."""
function load_target(path::String, flags::Flags)::Union{Nothing, ProjectFacts}
    root = project_root(path)
    project = isnothing(root) ? nothing : Discovery.project_facts(root)
    return loads(project, Config.settings(root, flags, REGISTRY)) ? project : nothing
end

"""One analysis of `path`: settings, facts, baseline root, leveled diagnostics with their baseline keys, and always-on check problems."""
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
    loaded = load_package(sources.project, settings, sources.files)
    facts = FactSet(sources.files, sources.entries, settings.bans, sources.project, loaded.facts, external_facts(loaded.facts, sources.files, settings))
    kept, problems = OptOuts.apply(facts, run_rules(facts), Set(rule.name for rule in REGISTRY))
    leveled = diagnostics(kept, settings)
    root = something(project, isdir(path) ? abspath(path) : dirname(abspath(path)))
    keys = Baseline.finding_keys(facts, root, [diagnostic.finding for diagnostic in leveled])
    checks = [
        [Diagnostic(problem, Level.deny, Syntax.PARSE_SOURCE) for problem in Syntax.parse_problems(facts)];
        [Diagnostic(problem, Level.deny, Package.LOAD_SOURCE) for problem in loaded.errors];
        [Diagnostic(problem, Level.deny, OptOuts.SOURCE) for problem in problems]
    ]
    blind_spots = [sources.blind_spots; loaded.blind_spots]
    return Analysis(settings, facts, root, leveled, keys, checks, blind_spots)
end

"""Report for files discovered from `path`; baseline at project root hides known findings."""
function check(path::String; flags::Flags = Flags())::Report
    analysis = analyze(path, flags)
    covered, stale = Baseline.cover(Baseline.read_baseline(analysis.root), analysis.keys)
    reported = [analysis.leveled[.!covered]; analysis.problems]
    sort!(reported; by = diagnostic -> (diagnostic.finding.primary.span.file, diagnostic.finding.primary.span.first_byte, diagnostic.finding.rule))
    sources = Dict(file.path => file.text for file in analysis.facts.files)
    # Load error, cause label and blind spot can point at file checked path leaves out.
    labels = [[diagnostic.finding.primary; diagnostic.finding.causes] for diagnostic in reported]
    for path in [[label.span.file for group in labels for label in group]; [spot.span.file for spot in analysis.blind_spots]]
        haskey(sources, path) || (sources[path] = read(path, String))
    end
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
