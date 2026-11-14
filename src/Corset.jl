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
include("Fixes.jl")
include("OptOuts.jl")
include("Baseline.jl")
include("Engine.jl")
include("Render.jl")
include("Output.jl")
include("CLI.jl")
include("InferenceSample.jl")

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
        code = CLI.execute(args, IOBuffer(), IOBuffer(); launch = false)
        code in (CLI.EXIT_PASS, CLI.EXIT_FAIL) || error("precompile workload: `corset $(join(args, ' '))` exited with $code")
    end
    return nothing
end

"""
Run `inference` stage on `InferenceSample`, so package image keeps inference of Base callees on stand-in types and
compiled source mapping.
"""
function inference_workload()::Nothing
    path = joinpath(@__DIR__, "InferenceSample.jl")
    files = [Syntax.parse_file(path, read(path, String), Facts.Role.package)]
    facts, _ = Inference.inference_facts(Package.package_facts([InferenceSample], files), files)
    isempty(facts.typed) && error("precompile workload: inference stage typed no sample method")
    return nothing
end

@setup_workload @compile_workload (mktempdir(workload); inference_workload())

"""Command-line entry point for `corset` app and `julia -m Corset`; package runs relaunch in temporary environment."""
function (@main)(args::Vector{String})::Int
    return CLI.execute(args, stdout, stderr; launch = true)
end

end
