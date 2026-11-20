using Serialization: deserialize

"""Call facts of one unit, each keyed by source statement and span, in statement order (`add_calls!`)."""
const UnitCalls = Vector{Pair{Tuple{Int, Span}, CallFact}}

"""
Effects of one unit for verdict of its method (`effects.md`, Units): accesses with cause spans, result aliases, holds
throws skip, call facts, blind spots, `closed_world`, span of cut that reaches unit (`nothing`: none), and whether
stand-ins cut own code (`own_cut`). Unit that always throws on stand-ins gives no verdict (`verdict` false), only its
blind spot. Method store entry of unit keeps record (`record_bytes`), so stored unit needs no typed code.
"""
struct UnitEffects
    verdict::Bool
    writes::Vector{Access}
    reads::Vector{Access}
    blind_writes::Vector{BlindAccess}
    blind_reads::Vector{BlindAccess}
    aliases::Vector{Place.Type}
    unguarded::Vector{UnguardedHold}
    calls::UnitCalls
    spots::Vector{BlindSpot}
    closed_world::Bool
    cut::Union{Nothing, Span}
    own_cut::Bool
end

"""Call facts of `root` with code in `run`, with spans from `span_of` (`root_calls`)."""
function unit_calls(run::Run, root::Variant, span_of::Function)::UnitCalls
    lines, found = run.codes[root].lines, UnitCalls()
    for (index, record) in root_calls(run, root)
        fact = CallFact(span_of(index), record...)
        push!(found, (lines[index], fact.span) => fact)
    end
    return found
end

"""Effects record of root unit `typed` with variant `root` in solved `run`."""
function unit_effects(run::Run, typed::TypedCode, root::Variant)::UnitEffects
    own_cut = !isempty(typed.cuts)
    # Unit that always throws on stand-ins shows no behavior of declared signature.
    typed.result === Union{} && return UnitEffects(
        false, Access[], Access[], BlindAccess[], BlindAccess[], Place.Type[], UnguardedHold[], UnitCalls(),
        [BlindSpot("always throws on stand-ins", typed.site.span)], false, nothing, own_cut,
    )
    summary = root_summary(run, root)
    span_of(cause::Int)::Span = cause_span(typed, run.codes[root], cause)
    kind_of(place::Place.Type)::EffectKind.T = path_kind(run.codes[root].ir, place)
    writes, blind_writes = unit_accesses(summary.writes, span_of, typed.provenance)
    held_writes, held_blind = lock_writes(summary, span_of, kind_of)
    unguarded, spots = unguarded_holds(summary, span_of)
    reads, blind_reads = unit_accesses(summary.reads, span_of, typed.provenance)
    cut = summary.cut ? cut_span(run, typed, root) : nothing
    return UnitEffects(
        true, [writes; held_writes], reads, [blind_writes; held_blind], blind_reads, result_aliases(summary), unguarded,
        unit_calls(run, root, span_of), spots, summary.closed_world, cut, own_cut,
    )
end

"""`record` with call facts `calls`."""
with_calls(record::UnitEffects, calls::UnitCalls)::UnitEffects = UnitEffects((name === :calls ? calls : getfield(record, name) for name in fieldnames(UnitEffects))...)

"""
Callee of call fact as method store keeps it: signatures of methods (`Callee.Methods`), name of intrinsic function, or
callee itself. Deserialized `Method` is new object outside method table, and intrinsic function has no serialization.
"""
function stored_callee(callee::Callee.Type)::Any
    return @match callee begin
        Callee.Methods(methods) => Type[method.sig for method in methods]
        Callee.Builtin(builtin) => builtin isa Core.IntrinsicFunction ? Symbol(builtin) : callee
        _ => callee
    end
end

"""Callee that `stored_callee` keeps as `stored`, methods found in `world`."""
loaded_callee(@nospecialize(stored::Any), world::UInt)::Callee.Type = stored isa Symbol ? Callee.Builtin(getfield(Core.Intrinsics, stored)) : stored isa Vector{Type} ? Callee.Methods(map(signature -> method_of(signature, world), stored)) : stored::Callee.Type

"""Method of `world` whose signature is `signature`; other method or none throws."""
function method_of(signature::Type, world::UInt)::Method
    method = Base._which(signature; world).method
    method.sig == signature || throw(ArgumentError("method store names method $signature, which world $world lacks"))
    return method
end

"""`fact` with callee `callee`."""
with_callee(fact::CallFact, callee::Callee.Type)::CallFact = CallFact((name === :callee ? callee : getfield(fact, name) for name in fieldnames(CallFact))...)

"""Call facts of unit as method store keeps them: fact with open callee, and its callee (`stored_callee`)."""
const StoredCalls = Vector{Tuple{Tuple{Int, Span}, CallFact, Any}}

"""Bytes of unit `record` for method store entry (`Inference.Entry`); `nothing` marks unit without code."""
function record_bytes(record::Union{Nothing, UnitEffects})::Vector{UInt8}
    isnothing(record) && return serialized(nothing)
    calls = StoredCalls([(key, with_callee(fact, Callee.Open()), stored_callee(fact.callee)) for (key, fact) in record.calls])
    return serialized((with_calls(record, UnitCalls()), calls))
end

"""
Unit record that method store entry keeps in `bytes` (`record_bytes`); callees come back in `world`. `nothing` for unit
without code. Entry without record throws: `effects` run infers such unit instead.
"""
function unit_record(bytes::Vector{UInt8}, world::UInt)::Union{Nothing, UnitEffects}
    isempty(bytes) && throw(ArgumentError("method store entry keeps no effects record; effects run must infer its unit"))
    stored = deserialize(IOBuffer(bytes))::Union{Nothing, Tuple{UnitEffects, StoredCalls}}
    isnothing(stored) && return nothing
    record, calls = stored
    return with_calls(record, UnitCalls([key => with_callee(fact, loaded_callee(callee, world)) for (key, fact, callee) in calls]))
end

"""
Effects record of each unit in inference order, with its method: typed unit takes its record in `fresh`, stored unit
(`Units.stored`) its record in `stored`. Order keeps first cause per access (`worst`), as run that infers all.
"""
function ordered_records(units::Units, fresh::Vector{Union{Nothing, UnitEffects}}, stored::Vector{Union{Nothing, UnitEffects}})::Vector{Pair{Method, Union{Nothing, UnitEffects}}}
    positions = [[(index, 0) for index in eachindex(units.typed)]; [(unit.position, 1) for unit in units.stored]]
    methods = Method[[typed.site.method for typed in units.typed]; [unit.site.method for unit in units.stored]]
    records = Union{Nothing, UnitEffects}[fresh; stored]
    return [methods[index] => records[index] for index in sortperm(positions)]
end
