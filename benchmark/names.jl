# Effects and lifecycle stage cost and precision on registered packages (docs/design/phase5.md, row 5 measure).
# Usage: julia benchmark/names.jl <corset-root> <work-directory> [Name@version ...]
# Each package runs in fresh Julia process, so `inference` stage time is cold.

using Pkg: Pkg

"""Packages phase 5 measures; numbers go to history."""
const CORPUS = ["Distances@0.10.12", "DataStructures@0.18.22", "SpecialFunctions@2.9.2", "StatsFuns@2.3.1", "Distributions@0.25.135"]

"""Child process: load target `ARGS[1]`, then time `inference`, `effects` and `lifecycle` stages on its copy `ARGS[2]`."""
const CHILD = raw"""
using Corset: Corset
using Corset.Effects: Effects
using Corset.Facts: Confidence, EffectKind
name, root = ARGS
Base.require(Main, Symbol(name))
sources = Corset.Discovery.discover(root; environment = nothing)
loaded = Corset.Package.load(sources.project, sources.files)
inference = @timed Corset.Inference.infer_package(loaded.facts, sources.files, nothing, nothing)
_, _, units, _ = inference.value
GC.gc()
# Each run starts from empty library summaries, so both runs solve same units.
effects = @timed Effects.effects_facts(loaded.facts, units, nothing, Effects.Summaries.Library())
GC.gc()
warm = @timed Effects.effects_facts(loaded.facts, units, nothing, Effects.Summaries.Library())
(; facts, spots, ordered) = effects.value
GC.gc()
lifecycle = @timed Corset.Lifecycle.lifecycle_facts(loaded.facts, ordered)
GC.gc()
warm_lifecycle = @timed Corset.Lifecycle.lifecycle_facts(loaded.facts, ordered)
methods = facts.methods
share(count::Int)::String = string(count, " (", round(100 * count / max(1, length(methods)); digits = 1), "%)")
println("units=", length(units.typed), " stored=", length(units.stored), " methods=", length(methods))
println("inference_s=", round(inference.time; digits = 2), " effects_s=", round(effects.time; digits = 2), " warm_effects_s=", round(warm.time; digits = 2), " ratio=", round(warm.time / inference.time; digits = 3))
stages = warm.time + warm_lifecycle.time
println("lifecycle_s=", round(lifecycle.time; digits = 3), " warm_lifecycle_s=", round(warm_lifecycle.time; digits = 3), " stages_ratio=", round(stages / inference.time; digits = 3))
println("effects_alloc_mb=", round(warm.bytes / 2^20; digits = 1), " maxrss_mb=", round(Sys.maxrss() / 2^20; digits = 1))
# Write kinds `bang-convention` exempts (`effects.md`, Effect kinds).
const EXEMPT = (EffectKind.io, EffectKind.default_rng, EffectKind.rng_argument, EffectKind.lazy_init, EffectKind.audited)
bang(access) = !(access.kind in EXEMPT)
println("write=", share(count(found -> !isempty(found.writes), methods)), " bang_write=", share(count(found -> any(bang, found.writes), methods)))
println("bang_definite=", share(count(found -> any(access -> bang(access) && access.confidence == Confidence.definite, found.writes), methods)), " bang_possible=", share(count(found -> any(access -> bang(access) && access.confidence == Confidence.possible, found.writes), methods)))
println("effect_free=", share(count(found -> found.effect_free, methods)), " incomplete=", share(count(found -> !found.complete, methods)))
kinds = Dict{EffectKind.T, Int}()
foreach(access -> kinds[access.kind] = get(kinds, access.kind, 0) + 1, (access for found in methods for access in [found.writes; found.reads]))
println("access_kinds=", sort!(collect(kinds); by = last, rev = true))
calls = [call for found in methods for call in found.calls]
println("calls=", length(calls), " discarded=", count(call -> !call.used, calls), " unused_call=", count(call -> !call.used && isempty(call.kinds) && !call.throws && call.terminates, calls))
causes = Dict{String, Int}()
foreach(spot -> causes[spot.cause] = get(causes, spot.cause, 0) + 1, spots)
println("spots=", sort!(collect(causes); by = last, rev = true))
# Location and source line of `span`: `path:line | text`.
function source_line(span::Corset.Facts.Span)::String
    text = read(span.file, String)
    line = count(==(UInt8('\n')), codeunits(text)[1:(span.first_byte - 1)]) + 1
    return string(relpath(span.file, root), ":", line, " | ", strip(split(text, '\n')[line]))
end
# Loop writes (F48) for quality gate audit: each with source line of write.
loops = [write for found in methods for write in found.loop_writes]
println("loop_writes=", length(loops), " definite=", count(write -> write.confidence == Confidence.definite, loops))
foreach(write -> println("  ", write.confidence, " ", write.callee, " ", source_line(write.write)), loops)
# Self-alias calls (F50) for quality gate audit.
selves = [call for found in methods for call in found.self_aliases]
println("self_aliases=", length(selves), " definite=", count(call -> call.confidence == Confidence.definite, selves))
foreach(call -> println("  ", call.confidence, " ", call.callee, " ", source_line(call.call)), selves)
# Stateful reuses (F51) for quality gate audit: later event, then earlier event.
reuses = [reuse for found in methods for reuse in found.stateful_reuses]
println("stateful_reuses=", length(reuses), " definite=", count(reuse -> reuse.confidence == Confidence.definite, reuses))
foreach(reuse -> println("  ", reuse.confidence, " ", something(reuse.iterator, "-"), " ", source_line(reuse.later), " <- ", source_line(reuse.earlier)), reuses)
# Unproven indices (F36) for quality gate audit: indexing call, then index source.
indices = [unproven for found in methods for unproven in found.indices.unproven]
println("unproven_indices=", length(indices), " definite=", count(unproven -> unproven.confidence == Confidence.definite, indices))
foreach(unproven -> println("  ", unproven.confidence, " ", something(unproven.array, "-"), " ", source_line(unproven.site), isnothing(unproven.source) ? "" : " <- " * source_line(something(unproven.source))), indices)
"""

"""Copy of registered package `name` at `version` in `work`, made writable, with library preset."""
function package_copy(work::String, name::String, version::String)::String
    entry = Pkg.activate(joinpath(work, "download-$name")) do
        Pkg.add(; name, version, io = devnull)
        return Base.locate_package(Base.identify_package(name))
    end
    copy = cp(dirname(dirname(entry)), joinpath(work, name); force = true)
    for (directory, _, files) in walkdir(copy), file in files
        chmod(joinpath(directory, file), 0o644)
    end
    open(io -> write(io, "\n[preferences.Corset]\nkind = \"library\"\n"), joinpath(copy, "Project.toml"), "a")
    return copy
end

"""Seconds child process gets before `timeout` stops it."""
const CHILD_SECONDS = 1800

"""Measure package `name` at `version` with Corset at `corset` in fresh process; child gets `CHILD_SECONDS`."""
function measure(corset::String, work::String, name::String, version::String)::Nothing
    copy, environment = package_copy(work, name, version), joinpath(work, "env-$name")
    Pkg.activate(environment) do
        Pkg.develop([Pkg.PackageSpec(; path = corset), Pkg.PackageSpec(; path = copy)]; io = devnull)
        Pkg.precompile(; io = devnull)
    end
    println("== ", name, "@", version)
    seconds = @elapsed child = run(ignorestatus(`timeout -s INT -k 30 $CHILD_SECONDS $(Base.julia_cmd()) --startup-file=no --project=$environment -e $CHILD -- $name $copy`))
    # Child that ignores INT dies by KILL (137), so elapsed time tells timeout from crash.
    success(child) || println("child exit ", child.exitcode, seconds >= CHILD_SECONDS ? " (timed out after $CHILD_SECONDS s)" : "")
    return nothing
end

"""Measure each package of `args[3:end]`, or `CORPUS`, with Corset at `args[1]` in work directory `args[2]`."""
function main(args::Vector{String})::Nothing
    corset, work = abspath(args[1]), abspath(args[2])
    mkpath(work)
    for package in (length(args) > 2 ? args[3:end] : CORPUS)
        name, version = split(package, '@')
        measure(corset, work, String(name), String(version))
    end
    return nothing
end

main(ARGS)
