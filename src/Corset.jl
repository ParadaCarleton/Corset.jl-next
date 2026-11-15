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
include("Inference.jl")
include("External.jl")
include("Launch.jl")
include("Cache.jl")
include("Fixes.jl")
include("OptOuts.jl")
include("Baseline.jl")
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

"""Run command line on `SAMPLE` in empty `directory`: every format, then fix, baseline, check and explain."""
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
    return nothing
end

"""Run package stages and every rule on package `modules` with analyzed `files`, their `entries`, module file `entry` and `project`."""
function package_rules(modules::Vector{Module}, files::Vector{Facts.SyntaxFile}, entries::Vector{String}, entry::String, project::Union{Nothing, Facts.ProjectFacts})::Facts.PackageFacts
    package = Package.package_facts(modules, files)
    Engine.run_rules(Facts.FactSet(files, entries, Facts.Ban[], project, package, External.external_facts(package, entry, files)))
    return package
end

"""
Run package stages and every rule on Corset itself, then on `PackageSample` with `inference` stage. Own source covers
wide range of syntax and project shape; sample covers interfaces and inference of Base callees on stand-in types.
"""
function package_workload()::Nothing
    root = dirname(@__DIR__)
    own = Discovery.discover(root; environment = joinpath(root, "Project.toml"))
    package_rules(Package.module_tree(Corset), own.files, own.entries, own.project.entry, own.project)
    path = joinpath(@__DIR__, "PackageSample.jl")
    files = [Syntax.parse_file(path, read(path, String), Facts.Role.package)]
    facts, _ = Inference.inference_facts(package_rules([PackageSample], files, [path], path, nothing), files)
    isempty(facts.typed) && error("precompile workload: inference stage typed no sample method")
    return nothing
end

@setup_workload @compile_workload (mktempdir(workload); package_workload())

"""Command-line entry point for `corset` app and `julia -m Corset`; package runs relaunch in temporary environment."""
function (@main)(args::Vector{String})::Int
    return CLI.execute(args, stdout, stderr; launch = true, cache = Cache.directory())
end

end
