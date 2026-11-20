"""Discover files, build facts, run registered rules; apply opt-outs, levels, confidence setting and baseline."""
module Engine

using ..Facts: Facts, FactSet, Finding, BlindSpot, RuleEntry, Confidence, Stage, ProjectFacts, PackageFacts, InferenceFacts, EffectsFacts, ExternalFacts
using ..Rules: REGISTRY, entry
using ..Config: Config, Flags, Settings, Level, level_of, project_root
using ..OptOuts: OptOuts
using ..Fixes: Fixes
using ..Baseline: Baseline
using ..Discovery: Discovery
using ..Syntax: Syntax
using ..Package: Package
using ..Inference: Inference
using ..Effects: Effects
using ..External: External
using ..Cache: Cache
using Serialization: serialize
using SHA: sha256

"""Finding with level from settings. `source` says where level was set."""
struct Diagnostic
    finding::Finding
    level::Level.T
    source::String
end

"""
Result of one run: diagnostics, settings, project root, source text per file, analyzed file count, baselined count,
stale baseline keys and blind spots. Sources also hold files that labels and blind spots outside analyzed files point at.
"""
struct Report
    diagnostics::Vector{Diagnostic}
    settings::Settings
    root::String
    sources::Dict{String, String}
    analyzed::Int
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

"""Whether `settings` enable any rule whose findings read `stage` last, or whose fixes read it."""
wants(settings::Settings, stage::Stage.T)::Bool = any(entry -> (entry.stage == stage || entry.fix_stage == stage) && enabled(settings, entry), REGISTRY)

"""Whether `settings` enable rule that reads `inference` stage, or stage built on its units: `effects`, `lifecycle`."""
needs_inference(settings::Settings)::Bool = any(stage -> wants(settings, stage), (Stage.inference, Stage.effects, Stage.lifecycle))

"""Whether `settings` enable rule that reads `effects` stage, or `lifecycle` stage built on it."""
needs_effects(settings::Settings)::Bool = wants(settings, Stage.effects) || wants(settings, Stage.lifecycle)

"""Whether `settings` enable any rule whose findings or fixes read stage after `syntax`."""
needs_package(settings::Settings)::Bool = any(entry -> entry.fix_stage != Stage.syntax && enabled(settings, entry), REGISTRY)

"""Whether run under `settings` loads package of `project`: package project, and enabled rule after `syntax` stage."""
loads(project::Union{Nothing, ProjectFacts}, settings::Settings)::Bool = !isnothing(project) && needs_package(settings)

"""
Loaded package of `project` with method sites in `files`, and its load errors and blind spots.
Nothing loads outside package project, and when no enabled rule reads package.
"""
function load_package(project::Union{Nothing, ProjectFacts}, settings::Settings, files::Vector{Facts.SyntaxFile})::Package.Loaded
    return loads(project, settings) ? Package.load(project, files) : Package.Loaded(nothing, Finding[], BlindSpot[])
end

"""Name of method store entry of checked `path` in cache directory, beside analysis entry of `path`."""
method_entry(path::String)::String = "$path\nmethod store"

"""Key of method store entry of checked `path` with `package` in analyzed `files` in cache directory `cache`."""
store_key(path::String, package::PackageFacts, files::Vector{Facts.SyntaxFile}, cache::String)::String =
    Cache.method_key(path, something(project_root(path)), [file.path for file in files], Inference.shape(package), Base.load_path(), cache)

"""
Inference and effects facts of `package` in analyzed `files`, each with its blind spots: inference facts when
`inference` holds, effects facts when `effects` holds too; else none. Cache directory `cache` keeps method store of
checked `path` and library summaries (`architecture.md`; `effects.md`, Solve and cache); `nothing` turns both off.
Crash journal `directory` of relaunched process records each inference (`journaled`); `nothing` records none.
"""
function stage_facts(path::String, package::Union{Nothing, PackageFacts}, files::Vector{Facts.SyntaxFile}, inference::Bool, effects::Bool, cache::Union{Nothing, String}, directory::Union{Nothing, String})::Tuple{Union{Nothing, InferenceFacts}, Vector{BlindSpot}, Union{Nothing, EffectsFacts}, Vector{BlindSpot}}
    (isnothing(package) || !inference) && return nothing, BlindSpot[], nothing, BlindSpot[]
    key = isnothing(cache) ? "" : store_key(path, package, files, cache)
    cached = isnothing(cache) ? nothing : something(Cache.lookup(Inference.Store, cache, method_entry(path), key), Inference.Store())
    # Entries of runs that crashed serve as store, so finished work stays done.
    store = isnothing(directory) ? cached : merge(something(cached, Inference.Store()), Inference.finished_store(Inference.records(directory)))
    # Effects run reads effects record of each stored unit, so entry without one infers again.
    effects && !isnothing(store) && filter!(pair -> !isempty(last(pair).effects), store)
    infer(journal::Union{Nothing, Inference.Journal}) = Inference.infer_package(package, files, store, journal)
    facts, spots, units, used = isnothing(directory) ? infer(nothing) : journaled(infer, directory)
    effects_found, effects_spots, records = effects ? effects_facts(package, units, cache, directory) : (nothing, BlindSpot[], nothing)
    isnothing(cache) || Cache.store!(cache, method_entry(path), key, isnothing(records) ? something(used) : with_records(something(used), units, records))
    return facts, spots, effects_found, effects_spots
end

"""
Store `used` where each entry without effects record takes one: typed unit of `units` its record in `records`, other
unit (no code) `nothing`. Stored entries keep theirs.
"""
function with_records(used::Inference.Store, units::Inference.Units, records::Vector{Union{Nothing, Effects.UnitEffects}})::Inference.Store
    bytes = Dict(Inference.entry_key(typed.site.method, typed.signature) => Effects.record_bytes(record) for (typed, record) in zip(units.typed, records))
    none = Effects.record_bytes(nothing)
    filled(key::String, entry::Inference.Entry)::Inference.Entry = Inference.Entry(entry.file, entry.methods, entry.staged, entry.inferred, get(bytes, key, none))
    return Inference.Store(key => isempty(entry.effects) ? filled(key, entry) : entry for (key, entry) in used)
end

"""
Effects facts of `package` from inference `units`, their blind spots, and effects record of each typed unit
(`Effects.cached_effects`). Cache directory `cache` serves and stores library summaries in library file of partition
(`Cache.partition_key`); `nothing` turns them off. Crash journal `directory` records native inference of library
instances.
"""
function effects_facts(package::PackageFacts, units::Inference.Units, cache::Union{Nothing, String}, directory::Union{Nothing, String})::Tuple{EffectsFacts, Vector{BlindSpot}, Vector{Union{Nothing, Effects.UnitEffects}}}
    library_directory = isnothing(cache) ? "" : Cache.library_directory(cache)
    partition = isnothing(cache) ? "" : Cache.partition_key(string(VERSION), DEPOT_PATH)
    library = Effects.Library(isnothing(cache) ? Dict{String, Cache.Stamped}() : Cache.read_library(library_directory, partition))
    solve(journal::Union{Nothing, Inference.Journal}) = Effects.cached_effects(package, units, journal, library)
    facts, spots, records, found, hits = isnothing(directory) ? solve(nothing) : journaled(solve, directory)
    isnothing(cache) || Cache.keep_library!(library_directory, partition, found.entries, hits, Cache.LIBRARY_BYTES)
    return facts, spots, records
end

"""
Facts that `infer` gives with journal of crash journal `directory`. Stderr goes to crash log meanwhile, so Julia abort
report of crash stays there; return or Julia exception copies log text of this run to stderr.
"""
function journaled(infer::Function, directory::String)::Tuple
    log = Inference.log_file(directory)
    start = isfile(log) ? filesize(log) : 0
    journal = Inference.open_journal(directory)
    try
        return open(stream -> redirect_stderr(() -> infer(journal), stream), log, "a")
    finally
        close(journal.io)
        write(stderr, open(stream -> (seek(stream, start); read(stream)), log))
    end
end

"""
External facts of `package` that `project` loads, with analyzed `files`, when `settings` enable `external` rule;
`nothing` otherwise.
"""
function external_facts(project::Union{Nothing, ProjectFacts}, package::Union{Nothing, PackageFacts}, files::Vector{Facts.SyntaxFile}, settings::Settings)::Union{Nothing, ExternalFacts}
    return isnothing(package) || !wants(settings, Stage.external) ? nothing : External.external_facts(package, project.entry, files)
end

"""Project facts of package run on `path` with `flags` loads; `nothing` when run loads no package."""
function load_target(path::String, flags::Flags)::Union{Nothing, ProjectFacts}
    root = project_root(path)
    project = isnothing(root) ? nothing : Discovery.project_facts(root; environment = nothing)
    return loads(project, Config.settings(root, flags, REGISTRY)) ? project : nothing
end

"""
Analysis of checked path that disk cache stores: baseline root, analyzed files, leveled diagnostics with their baseline
keys, always-on check problems and blind spots.
"""
struct Analysis
    root::String
    files::Vector{String}
    leveled::Vector{Diagnostic}
    keys::Vector{Baseline.Key}
    problems::Vector{Diagnostic}
    blind_spots::Vector{BlindSpot}
end

"""
Facts and analysis of real `path` with discovered `sources` under `settings`. Opt-outs apply before levels. Cache
directory `cache` keeps method store and library summaries unless `nothing`; crash `journal` directory as in `stage_facts`.
"""
function analyze(path::String, settings::Settings, sources::Discovery.Sources, cache::Union{Nothing, String}, journal::Union{Nothing, String})::Tuple{FactSet, Analysis}
    loaded = load_package(sources.project, settings, sources.files)
    # Target methods are newer than this call; in its world, `Float32(::TargetIrrational)` throws and `show` falls back.
    return Base.invokelatest(analyze_loaded, path, settings, sources, cache, journal, loaded)::Tuple{FactSet, Analysis}
end

"""Facts and analysis of `analyze` once package of `sources` is `loaded`; runs in world that sees package methods."""
function analyze_loaded(path::String, settings::Settings, sources::Discovery.Sources, cache::Union{Nothing, String}, journal::Union{Nothing, String}, loaded::Package.Loaded)::Tuple{FactSet, Analysis}
    inference, inference_spots, effects, effects_spots = stage_facts(path, loaded.facts, sources.files, needs_inference(settings), needs_effects(settings), cache, journal)
    facts = FactSet(sources.files, sources.entries, settings.bans, sources.project, loaded.facts, inference, effects, external_facts(sources.project, loaded.facts, sources.files, settings))
    kept, problems = OptOuts.apply(facts, run_rules(facts), Set(rule.name for rule in REGISTRY))
    leveled = diagnostics(kept, settings)
    root = something(project_root(path), isdir(path) ? path : dirname(path))
    keys = Baseline.finding_keys(facts, root, [diagnostic.finding for diagnostic in leveled])
    checks = [
        [Diagnostic(problem, Level.deny, Syntax.PARSE_SOURCE) for problem in Syntax.parse_problems(facts)];
        [Diagnostic(problem, Level.deny, Package.LOAD_SOURCE) for problem in loaded.errors];
        [Diagnostic(problem, Level.deny, OptOuts.SOURCE) for problem in problems]
    ]
    blind_spots = [sources.blind_spots; loaded.blind_spots; inference_spots; effects_spots]
    return facts, Analysis(root, [file.path for file in sources.files], leveled, keys, checks, blind_spots)
end

"""
Key in cache directory `cache` of run on real `path` with `flags` and discovered `sources`, in process with `load_path`.
Flags count by serialized bytes: `repr` names types relative to `Main` imports, which differ between processes.
"""
function cache_key(path::String, flags::Flags, sources::Discovery.Sources, load_path::Vector{String}, cache::String)::String
    flags_hash = bytes2hex(sha256(sprint(serialize, flags)))
    return Cache.key(path, flags_hash, project_root(path), [file.path for file in sources.files], load_path, cache)
end

"""
Real `path`, settings from config of enclosing project and command-line `flags`, and sources `Discovery.discover` picks.
Project facts come from active environment, which package stage loads package from.
"""
function inputs(path::String, flags::Flags)::Tuple{String, Settings, Discovery.Sources}
    # Relaunch develops package at real path, so Julia records method files there; analyzed files must match.
    path = realpath(path)
    return path, Config.settings(project_root(path), flags, REGISTRY), Discovery.discover(path; environment = Base.active_project())
end

"""
Settings and analysis of `path` with `flags`; cache directory `cache` serves and stores analysis unless `nothing`.
Crash `journal` directory of relaunched process records inferences (`stage_facts`); `nothing` records none.
"""
function analysis(path::String, flags::Flags, cache::Union{Nothing, String}, journal::Union{Nothing, String})::Tuple{Settings, Analysis}
    path, settings, sources = inputs(path, flags)
    isnothing(cache) && return settings, last(analyze(path, settings, sources, nothing, journal))
    key = cache_key(path, flags, sources, Base.load_path(), cache)
    stored = Cache.lookup(Analysis, cache, path, key)
    isnothing(stored) || return settings, stored
    fresh = last(analyze(path, settings, sources, cache, journal))
    Cache.store!(cache, path, key, fresh)
    return settings, fresh
end

"""
Settings and analysis that cache directory `cache` holds for run on `path` with `flags`, in process with `load_path`;
`nothing` when cache misses. Relaunching process asks before it relaunches: hit loads no package.
"""
function cached(path::String, flags::Flags, cache::String, load_path::Vector{String})::Union{Nothing, Tuple{Settings, Analysis}}
    path = realpath(path)
    sources = Discovery.discover(path; environment = nothing)
    stored = Cache.lookup(Analysis, cache, path, cache_key(path, flags, sources, load_path, cache))
    return isnothing(stored) ? nothing : (Config.settings(project_root(path), flags, REGISTRY), stored)
end

"""Report of `analyzed` under `settings`; baseline at project root hides known findings."""
function report(settings::Settings, analyzed::Analysis)::Report
    covered, stale = Baseline.cover(Baseline.read_baseline(analyzed.root), analyzed.keys)
    reported = [analyzed.leveled[.!covered]; analyzed.problems]
    sort!(reported; by = diagnostic -> (diagnostic.finding.primary.span.file, diagnostic.finding.primary.span.first_byte, diagnostic.finding.rule))
    sources = Dict(file => read(file, String) for file in analyzed.files)
    # Load error, cause label and blind spot can point at file checked path leaves out.
    labels = [[diagnostic.finding.primary; diagnostic.finding.causes] for diagnostic in reported]
    for path in [[label.span.file for group in labels for label in group]; [spot.span.file for spot in analyzed.blind_spots]]
        haskey(sources, path) || (sources[path] = read(path, String))
    end
    return Report(reported, settings, analyzed.root, sources, length(analyzed.files), count(covered), stale, analyzed.blind_spots)
end

"""
Report for files discovered from `path`; cache directory `cache` serves and stores analysis unless `nothing`. Only
relaunched process passes crash `journal` directory.
"""
check(path::String; flags::Flags = Flags(), cache::Union{Nothing, String} = nothing, journal::Union{Nothing, String} = nothing)::Report = report(analysis(path, flags, cache, journal)...)

"""Write baseline of `analyzed` at its project root from every reported finding; return entry count."""
function baseline(analyzed::Analysis)::Int
    Baseline.write_baseline(analyzed.root, analyzed.keys)
    return length(analyzed.keys)
end

"""Write baseline at project root of `path` from every reported finding; return entry count. `cache` as in `check`."""
baseline(path::String; flags::Flags = Flags(), cache::Union{Nothing, String} = nothing)::Int = baseline(last(analysis(path, flags, cache, nothing)))

"""
Apply fixes of reported findings under `path` up to fix tier. Return number of edits applied, and whether check of
edited files needs fresh process: run loaded package, whose methods keep code from before edits. `cache`, `journal` as
in `check`.
"""
function fix!(path::String; flags::Flags = Flags(), cache::Union{Nothing, String} = nothing, journal::Union{Nothing, String} = nothing)::Tuple{Int, Bool}
    _, settings, sources = inputs(path, flags)
    report = check(path; flags, cache, journal)
    edits = Fixes.applicable_edits([diagnostic.finding for diagnostic in report.diagnostics], report.settings.tier)
    # Fix may span files; edit in unread file throws `KeyError` before any write.
    files = unique(edit.span.file for edit in edits)
    fixed = Dict(file => Fixes.apply_edits(report.sources[file], filter(edit -> edit.span.file == file, edits)) for file in files)
    foreach(((file, text),) -> write(file, text), fixed)
    return length(edits), !isempty(edits) && loads(sources.project, settings)
end

end
