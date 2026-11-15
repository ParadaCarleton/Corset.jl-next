# Cold `corset check` time on registered packages, in scope of speed budget (docs/design/plan.md).
# Usage: julia benchmark/cold.jl <work-directory> [Name@version ...]
# Each package runs in fresh Julia process that loads target first: Julia startup and target load stay out.

using Pkg: Pkg

"""Packages legacy baseline in docs/design/plan.md measures."""
const CORPUS = ["Distances@0.10.12", "DataStructures@0.18.22", "JSON@1.13.4"]

"""Child process: load target `ARGS[1]`, then time `corset check` on its copy `ARGS[2]` and `inference` stage."""
const CHILD = raw"""
using Corset: Corset
name, root = ARGS
Base.require(Main, Symbol(name))
# Inference stage runs outside check until rule needs it; then check time covers it.
any(entry -> entry.stage == Corset.Facts.Stage.inference, Corset.Rules.REGISTRY) && error("check runs inference stage: drop separate timing")
# Disk cache would skip analysis this benchmark times.
check = @elapsed code = Corset.CLI.execute(["check", root], IOBuffer(), IOBuffer(); launch = false, cache = nothing)
code in (Corset.CLI.EXIT_PASS, Corset.CLI.EXIT_FAIL) || error("corset check exited with $code")
sources = Corset.Discovery.discover(root; environment = Base.active_project())
inference = @elapsed Corset.Inference.inference_facts(Corset.Package.load(sources.project, sources.files).facts, sources.files)
print(check, " ", inference)
"""

"""Writable copy of registered package `name` at `version` in `work`, with project kind `library`."""
function package_copy(work::String, name::String, version::String)::String
    entry = Pkg.activate(joinpath(work, "download-$name")) do
        Pkg.add(; name, version, io = devnull)
        return Base.locate_package(Base.identify_package(name))
    end
    copy = cp(dirname(dirname(entry)), joinpath(work, name); force = true)
    # Depot files are read-only.
    for (directory, _, files) in walkdir(copy), file in files
        chmod(joinpath(directory, file), 0o644)
    end
    open(io -> write(io, "\n[preferences.Corset]\nkind = \"library\"\n"), joinpath(copy, "Project.toml"), "a")
    return copy
end

"""Seconds of cold `corset check` and `inference` stage on registered package `name` at `version`."""
function cold_run(work::String, name::String, version::String)::Tuple{Float64, Float64}
    copy, environment = package_copy(work, name, version), joinpath(work, "env-$name")
    Pkg.activate(environment) do
        Pkg.develop([Pkg.PackageSpec(; path = dirname(@__DIR__)), Pkg.PackageSpec(; path = copy)]; io = devnull)
        Pkg.precompile(; io = devnull)
    end
    output = readchomp(`$(Base.julia_cmd()) --startup-file=no --project=$environment -e $CHILD -- $name $copy`)
    check, inference = parse.(Float64, split(output))
    return check, inference
end

function main(args::Vector{String})::Nothing
    isempty(args) && error("usage: julia benchmark/cold.jl <work-directory> [Name@version ...]")
    work = abspath(first(args))
    mkpath(work)
    println("package          check  inference  total (s)")
    for package in (length(args) > 1 ? args[2:end] : CORPUS)
        name, version = split(package, '@')
        check, inference = cold_run(work, String(name), String(version))
        println(rpad(name, 16), lpad(round(check; digits = 1), 6), lpad(round(inference; digits = 1), 11), lpad(round(check + inference; digits = 1), 7))
    end
    return nothing
end

main(ARGS)
