"""
Julia code-quality checker; rewrite in progress. Legacy implementation lives in `lib/CorsetLegacy`.

Stages build facts (`Facts`), rules turn facts into findings (`Rules`), `Config` sets levels, `Engine` runs them.
"""
module Corset

include("Facts.jl")
include("StandIns.jl")
include("Signatures.jl")
include("Syntax.jl")
include("Rules.jl")
include("Config.jl")
include("Discovery.jl")
include("Package.jl")
include("Widening.jl")
include("HardArrays.jl")
include("Guesses.jl")
include("Narrowing.jl")
include("Inference.jl")
include("Cache.jl")
include("Launch.jl")
include("Effects/Effects.jl")
include("Lifecycle.jl")
include("External.jl")
include("Fixes.jl")
include("OptOuts.jl")
include("Baseline.jl")
include("Timings.jl")
include("Engine.jl")
include("Render.jl")
include("Output.jl")
include("CLI.jl")
include("PackageSample.jl")

using .Engine: check
public check
using PrecompileTools: @compile_workload, @setup_workload

"""Script precompile workload checks: rules find something in it, and every output format and fix path runs."""
const SAMPLE = """
const WORKERS = Threads.nthreads()
values = []
total = 1.0
total ≈ 0
reach(value::Real)::Bool = value ≈ 0
task = @async reach(1)
ENV["MODE"] = "fast"
function pick(flag::Bool)
    flag && return 1
    "no"
end
"""

"""
Run command line on `SAMPLE` in empty `directory`: every format, then fix, baseline, check and explain. Then ask cache
for sample analysis, as relaunching process does before relaunch.
"""
function workload(directory::String)::Nothing
    # Own Project.toml makes `directory` project root, so baseline cannot land in project above it.
    write(joinpath(directory, "Project.toml"), "[preferences.Corset]\nkind = \"library\"\n")
    script = joinpath(directory, "sample.jl")
    write(script, SAMPLE)
    commands = [["check", script, "--format", format] for format in ("text", "json", "sarif")]
    for args in [commands; [["fix", script], ["baseline", script], ["check", script], ["explain", "approx-zero"]]]
        code = CLI.execute(args, IOBuffer(), IOBuffer(); launch = false, cache = joinpath(directory, "cache"))
        code in (CLI.EXIT_PASS, CLI.EXIT_FAIL) || error("precompile workload: `corset $(join(args, ' '))` exited with $code")
    end
    isnothing(Engine.cached(script, Config.Flags(), joinpath(directory, "cache"), Base.load_path())) && error("precompile workload: cache missed sample analysis")
    return nothing
end

"""
Run `external` stage and every rule on `package`, `inference`, `effects` and `lifecycle` facts of analyzed `files`,
their `entries`, module file `entry` and `project`.
"""
function package_rules(package::Facts.PackageFacts, inference::Union{Nothing, Facts.InferenceFacts}, effects::Union{Nothing, Facts.EffectsFacts}, lifecycle::Union{Nothing, Facts.LifecycleFacts}, files::AbstractVector{Facts.SyntaxFile}, entries::AbstractVector{String}, entry::String, project::Union{Nothing, Facts.ProjectFacts})::Nothing
    Engine.run_rules(Facts.FactSet(files, entries, Facts.Ban[], project, package, inference, effects, lifecycle, External.external_facts(package, entry, files)))
    return nothing
end

"""
Run package stages and every rule on Corset itself, then on `PackageSample` with `inference` and `effects` stages. Own
source covers wide range of syntax and project shape; sample covers interfaces and inference of Base callees on stand-in
types. Own project also keys temporary environment, as relaunching process does before cache lookup.
"""
function package_workload()::Nothing
    root = dirname(@__DIR__)
    own = Discovery.discover(root; environment = joinpath(root, "Project.toml"))
    package_rules(Package.package_facts(Package.module_tree(Corset), own.files), nothing, nothing, nothing, own.files, own.entries, own.project.entry, own.project)
    Launch.cache_key(own.project)
    path = joinpath(@__DIR__, "PackageSample.jl")
    files = [Syntax.parse_file(path, read(path, String), Facts.Role.package)]
    package = Package.package_facts([PackageSample], files)
    # Second run takes method store and library summaries from first, as rerun of `corset check` does.
    mktempdir() do cache
        Engine.stage_facts(path, package, files, true, true, true, cache, nothing, nothing)
        store = Cache.lookup(Inference.Store, cache, Engine.method_entry(path), Engine.store_key(path, package, files, cache); root = nothing)
        isempty(something(store, Inference.Store())) && error("precompile workload: inference stage stored no sample method")
        library = Cache.read_library(Cache.library_directory(cache), Cache.partition_key(string(VERSION)))
        isempty(library) && error("precompile workload: effects stage stored no library summary")
        inference, _, effects, _, lifecycle = Engine.stage_facts(path, package, files, true, true, true, cache, nothing, nothing)
        package_rules(package, inference, effects, lifecycle, files, [path], path, nothing)
        # Fresh units read library summaries, as check of other package does.
        _, _, units, _ = Inference.infer_package(package, files, nothing, nothing)
        isempty(Effects.effects_facts(package, units, nothing, Effects.Summaries.Library(library)).hits) && error("precompile workload: effects stage hit no library summary")
    end
    return nothing
end

@setup_workload @compile_workload (mktempdir(workload); package_workload())

"""Command-line entry point for `corset` app and `julia -m Corset`; package runs relaunch in temporary environment."""
function (@main)(args::Vector{String})::Int
    return CLI.execute(args, stdout, stderr; launch = true, cache = Cache.directory())
end

end
