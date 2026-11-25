# Effects facts of package as sorted text, one access per line; optional dump of every solved summary.
# Usage: julia --project=<work>/env-<Name> diagnostics/dump_facts.jl <Name> <work>/<Name> <facts.txt> [<summaries.txt>]
# `benchmark/effects.jl` makes <work>. Compare two fact dumps with `diff`; two summary dumps with `summary_leaves.jl`.

using Corset: Corset
using Corset.Effects.Summaries: Summaries, Summary, Variant, solve!, start_run, unit_body

"""Text of `x` with every dictionary and set in sorted order, so equal values give equal text."""
canon(x::AbstractDict)::String = "{" * join(sort!([canon(key) * " => " * canon(item) for (key, item) in x]), ", ") * "}"
canon(x::AbstractSet)::String = "Set[" * join(sort!([canon(item) for item in x]), ", ") * "]"
canon(x::Base.IdSet)::String = "IdSet[" * join(sort!([canon(item) for item in x]), ", ") * "]"
canon(x::AbstractVector)::String = "[" * join([canon(item) for item in x], ", ") * "]"
canon(x::Tuple)::String = "(" * join([canon(item) for item in x], ", ") * ")"
canon(x::Pair)::String = canon(x.first) * " => " * canon(x.second)
canon(x::Core.MethodInstance)::String = variant_key((x, Pair{Int, Any}[]))
canon(x::Summary)::String = join([string(field, "=", canon(getfield(x, field))) for field in fieldnames(Summary)], " | ")
canon(x::Any)::String = repr(x)

"""Key of `variant`: method with module and location, specialization types, constant arguments."""
variant_key(variant::Variant)::String = string(first(variant).def, " ", first(variant).specTypes, " ", canon(last(variant)))

"""Write sorted fact lines of engine verdicts `facts` to `path`; return line count."""
function write_facts(facts::AbstractVector{Summaries.MethodVerdict}, path::String)::Int
    span(spot::Any)::String = string(basename(spot.file), ":", spot.first_byte)
    lines = String[]
    for found in facts
        label = string(found.site.method.module, ".", found.site.method.name, " ", found.site.method.sig)
        append!(lines, [string(label, " | write ", a.place, " ", a.below, " ", a.kind, " ", a.confidence, " ", span(a.cause)) for a in found.writes])
        append!(lines, [string(label, " | read ", a.place, " ", a.below, " ", a.kind, " ", a.confidence, " ", span(a.cause)) for a in found.reads])
        append!(lines, [string(label, " | blind_write ", a.place, " ", a.below, " ", a.spot.cause, " ", span(a.spot.span)) for a in found.blind_writes])
        append!(lines, [string(label, " | blind_read ", a.place, " ", a.below, " ", a.spot.cause, " ", span(a.spot.span)) for a in found.blind_reads])
    end
    sort!(lines)
    write(path, join(lines, "\n"), "\n")
    return length(lines)
end

"""Write each solved summary of run over `units` to `path`: key, summary, callee keys; return summary count."""
function write_summaries(modules::Vector{Module}, units::Any, path::String)::Int
    run = start_run(nothing, modules)
    firsts = IdDict{Core.MethodInstance, Any}()
    foreach(typed -> get!(firsts, typed.frame.linfo, typed), units.typed)
    roots = Variant[(typed.frame.linfo, Pair{Int, Any}[]) for typed in units.typed if firsts[typed.frame.linfo] === typed]
    foreach(((instance, _),) -> run.cuts[instance] = !isempty(firsts[instance].cuts), roots)
    foreach(((instance, _),) -> run.bodies[instance] = unit_body(run, firsts[instance].frame, run.cuts[instance]), roots)
    solve!(run, roots)
    open(path, "w") do io
        for (variant, summary) in run.summaries
            callees = haskey(run.codes, variant) ? unique!([variant_key(callee) for callees in run.codes[variant].callees for callee in callees]) : String[]
            println(io, variant_key(variant), "\t", canon(summary), "\t", join(callees, "\x1f"))
        end
    end
    return length(run.summaries)
end

"""Dump facts of package `name` at `root` to `facts_path`; summaries too when `summaries_path` is given."""
function dump(name::String, root::String, facts_path::String, summaries_path::Union{Nothing, String})::Nothing
    Base.require(Main, Symbol(name))
    sources = Corset.Discovery.discover(root; environment = nothing)
    loaded = Corset.Package.load(sources.project, sources.files)
    _, _, units, _ = Corset.Inference.infer_package(loaded.facts, sources.files, nothing, nothing)
    facts = first(Summaries.cached_effects(loaded.facts, units, Union{Nothing, Summaries.UnitVerdict}[], nothing, Summaries.Library()))
    print("facts=", write_facts(facts, facts_path))
    isnothing(summaries_path) || print(" summaries=", write_summaries(loaded.facts.modules, units, summaries_path))
    println()
    return nothing
end

Base.invokelatest(dump, ARGS[1], ARGS[2], ARGS[3], length(ARGS) >= 4 ? ARGS[4] : nothing)
