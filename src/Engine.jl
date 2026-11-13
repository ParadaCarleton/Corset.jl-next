"""Discover files, build facts, run registered rules; apply opt-outs, levels, confidence setting and baseline."""
module Engine

using ..Facts: Facts, FactSet, Finding, BlindSpot, RuleEntry, Confidence, Stage, PackageFacts
using ..Rules: REGISTRY, entry
using ..Config: Config, Flags, Settings, Level, level_of, project_root
using ..OptOuts: OptOuts
using ..Fixes: Fixes
using ..Baseline: Baseline
using ..Discovery: Discovery
using ..Syntax: Syntax
using ..Package: Package

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

"""Whether `settings` enable any rule that reads stage after `syntax`."""
needs_package(settings::Settings)::Bool = any(entry -> entry.stage != Stage.syntax && first(level_of(settings, entry)) != Level.allow, REGISTRY)

"""
Loaded package of named `project` with method sites in `files`, or `load-error` finding.
`nothing` outside named project, and when no enabled rule reads package.
"""
function load_package(project::Union{Nothing, String}, settings::Settings, files::Vector{Facts.SyntaxFile})::Union{Nothing, PackageFacts, Finding}
    id = load_target(project, settings)
    return isnothing(id) ? nothing : Package.load(project, id, files)
end

"""Package run loads from `project` under `settings`: named project with enabled rule after `syntax` stage."""
function load_target(project::Union{Nothing, String}, settings::Settings)::Union{Nothing, Base.PkgId}
    (isnothing(project) || !needs_package(settings)) && return nothing
    return Package.package_id(project)
end

"""Project root and package that run on `path` with `flags` loads; `nothing` when run loads no package."""
function load_target(path::String, flags::Flags)::Union{Nothing, Tuple{String, Base.PkgId}}
    project = project_root(path)
    id = load_target(project, Config.settings(project, flags, REGISTRY))
    return isnothing(id) ? nothing : (project, id)
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
    loaded = load_package(project, settings, sources.files)
    facts = FactSet(sources.files, sources.entries, settings.bans, loaded isa PackageFacts ? loaded : nothing)
    kept, problems = OptOuts.apply(facts, run_rules(facts), Set(rule.name for rule in REGISTRY))
    leveled = diagnostics(kept, settings)
    root = something(project, isdir(path) ? abspath(path) : dirname(abspath(path)))
    keys = Baseline.finding_keys(facts, root, [diagnostic.finding for diagnostic in leveled])
    failed_load = loaded isa Finding ? [loaded] : Finding[]
    checks = [
        [Diagnostic(problem, Level.deny, Syntax.PARSE_SOURCE) for problem in Syntax.parse_problems(facts)];
        [Diagnostic(problem, Level.deny, Package.LOAD_SOURCE) for problem in failed_load];
        [Diagnostic(problem, Level.deny, OptOuts.SOURCE) for problem in problems]
    ]
    blind_spots = [sources.blind_spots; [BlindSpot("package did not load", problem.primary.span) for problem in failed_load]]
    return Analysis(settings, facts, root, leveled, keys, checks, blind_spots)
end

"""Report for files discovered from `path`; baseline at project root hides known findings."""
function check(path::String; flags::Flags = Flags())::Report
    analysis = analyze(path, flags)
    covered, stale = Baseline.cover(Baseline.read_baseline(analysis.root), analysis.keys)
    reported = [analysis.leveled[.!covered]; analysis.problems]
    sort!(reported; by = diagnostic -> (diagnostic.finding.primary.span.file, diagnostic.finding.primary.span.first_byte, diagnostic.finding.rule))
    sources = Dict(file.path => file.text for file in analysis.facts.files)
    # Load error can point at package entry file when checked path leaves it out.
    for diagnostic in reported
        path = diagnostic.finding.primary.span.file
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
