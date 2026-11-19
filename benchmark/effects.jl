# Effects engine cost and precision on registered packages (docs/design/phase5.md, Measure).
# Usage: julia benchmark/effects.jl <corset-root> <work-directory> [Name@version ...]
# Each package runs in fresh Julia process: library inference is cold and no summary cache exists.

using Pkg: Pkg

"""Packages phase 5 measures; numbers go to history, "Phase 5 call resolution"."""
const CORPUS = ["Distances@0.10.12", "DataStructures@0.18.22", "JSON@1.13.4"]

"""Child process: load target `ARGS[1]`, then time `effects` stage on its copy `ARGS[2]` and count its run."""
const CHILD = raw"""
using Corset: Corset
using Corset.Effects: Effects, start_run, solve!, Variant, Outcome
# Older Corset builds every unit body; newer one may shortcut it (`instance_body`), then also knows stand-in cuts.
const cuts = isdefined(Effects, :stand_in_cut)
unit_body(run, typed) = cuts ? Effects.instance_body(run, typed.frame, run.cuts[typed.frame.linfo]) : isdefined(Effects, :instance_body) ? Effects.instance_body(run, typed.frame) : Effects.frame_body(run, typed.frame)
using Corset.Facts: Confidence
name, root = ARGS
Base.require(Main, Symbol(name))
sources = Corset.Discovery.discover(root; environment = nothing)
loaded = Corset.Package.load(sources.project, sources.files)
inference = @timed Corset.Inference.infer_package(loaded.facts, sources.files, nothing, nothing)
_, _, units, _ = inference.value
# Solve every unit as `effects_facts` does; return run for counts.
function solved(units)
    run = start_run(nothing, loaded.facts.modules)
    firsts = IdDict{Core.MethodInstance, Any}()
    foreach(typed -> get!(firsts, typed.frame.linfo, typed), units.typed)
    roots = Variant[(typed.frame.linfo, Pair{Int, Any}[]) for typed in units.typed if firsts[typed.frame.linfo] === typed]
    cuts && foreach(((instance, _),) -> run.cuts[instance] = !isempty(firsts[instance].cuts), roots)
    foreach(((instance, _),) -> run.bodies[instance] = unit_body(run, firsts[instance]), roots)
    solve!(run, roots)
    return run
end
# Effects first, so its time includes cold native inference of library instances.
GC.gc()
effects = @timed Effects.effects_facts(loaded.facts, units, nothing)
GC.gc()
solve = @timed solved(units)
facts, spots = effects.value
methods = facts.methods
possible = count(found -> any(access -> access.confidence == Confidence.possible, found.writes), methods)
definite = count(found -> any(access -> access.confidence == Confidence.definite, found.writes), methods)
blind = count(found -> !isempty(found.blind_writes), methods)
causes = Dict{String, Int}()
foreach(spot -> causes[spot.cause] = get(causes, spot.cause, 0) + 1, spots)
run = solve.value
library = count(body -> body isa String, values(run.bodies))
shortcuts = isdefined(Effects, :Shortcut) ? count(body -> body isa Effects.Shortcut, values(run.bodies)) : 0
println("units=", length(units.typed), " instances=", length(run.bodies), " variants=", length(run.summaries), " failed_bodies=", library, " shortcuts=", shortcuts)
println("inference_s=", round(inference.time; digits = 2), " effects_s=", round(effects.time; digits = 2), " warm_solve_s=", round(solve.time; digits = 2))
# Warm solve allocation counts engine only; `effects` allocation also counts cold native inference.
println("effects_alloc_mb=", round(effects.bytes / 2^20; digits = 1), " warm_solve_alloc_mb=", round(solve.bytes / 2^20; digits = 1), " maxrss_mb=", round(Sys.maxrss() / 2^20; digits = 1))
println("methods=", length(methods), " possible_write=", possible, " (", round(100 * possible / max(1, length(methods)); digits = 1), "%) definite_write=", definite, " blind_write=", blind)
println("spots=", sort!(collect(causes); by = last, rev = true))
closed = count(found -> found.closed_world, methods)
unsettled = count(found -> any(access -> access.spot.cause == Effects.UNSETTLED, [found.blind_writes; found.blind_reads]), methods)
# Variant names, not patterns: older Corset lacks newer outcome kinds. Moshi is Corset dependency, not direct one.
variant_name = only(m for m in values(Base.loaded_modules) if nameof(m) === :Moshi).Data.variant_name
kinds = Dict{String, Int}()
for body in values(run.bodies), outcome in (body isa Effects.Body ? body.outcomes : ())
    isnothing(outcome) && continue
    kind = string(variant_name(something(outcome)))
    width = Effects.@match something(outcome) begin
        Outcome.Dispatch(instances, _) => length(instances)
        _ => 0
    end
    width > 0 && (kind *= " " * string(width))
    kinds[kind] = get(kinds, kind, 0) + 1
end
println("closed_world=", closed, " unsettled=", unsettled, " calls=", sort!(collect(kinds)))
incomplete = count(found -> !found.complete, methods)
if cuts
    cut_units = count(typed -> !isempty(typed.cuts), units.typed)
    cut_bodies = count(body -> body isa Effects.Body && body.cut, values(run.bodies))
    println("incomplete=", incomplete, " cut_units=", cut_units, " cut_checks=", length(run.cuts), " cut_instances=", count(values(run.cuts)), " cut_bodies=", cut_bodies)
else
    println("incomplete=", incomplete)
end
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

"""Measure package `name` at `version` with Corset at `corset` in fresh process; child gets 30 min."""
function measure(corset::String, work::String, name::String, version::String)::Nothing
    copy, environment = package_copy(work, name, version), joinpath(work, "env-$name")
    Pkg.activate(environment) do
        Pkg.develop([Pkg.PackageSpec(; path = corset), Pkg.PackageSpec(; path = copy)]; io = devnull)
        Pkg.precompile(; io = devnull)
    end
    println("== ", name, "@", version)
    child = run(ignorestatus(`timeout -s INT -k 30 1800 $(Base.julia_cmd()) --startup-file=no --project=$environment -e $CHILD -- $name $copy`))
    success(child) || println("child exit ", child.exitcode, child.exitcode == 124 ? " (timed out after 1800 s)" : "")
    return nothing
end

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
