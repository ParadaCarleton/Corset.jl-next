using Serialization: deserialize

"""
Access Corset cannot judge (`engine.md`, Facts): place, whether it covers places below, kind, and blind spot with cause
(`alias` for collapsed path or merged call result). It counts on coverage line only.
"""
struct BlindAccess
    place::Place.Type
    below::Bool
    kind::EffectKind.T
    spot::BlindSpot
end

"""
Call statement as engine resolves it (`engine.md`, Facts): span, callee, kinds of writes call makes at any certainty,
holds it leaves included. Compiler effects give `throws` (may throw) and `terminates`. `used`: code reads result.
"""
struct CallSummary
    span::Span
    callee::Callee.Type
    kinds::Vector{EffectKind.T}
    throws::Bool
    terminates::Bool
    used::Bool
end

"""Call summaries of one unit, each keyed by source statement and span, in statement order (`add_calls!`)."""
const UnitCalls = Vector{Pair{Tuple{Int, Span}, CallSummary}}

"""
Verdict of one unit for verdict of its method (`engine.md`, Units): accesses with cause spans, result aliases, holds
throws skip, call summaries, blind spots, `closed_world`, span of cut that reaches unit (`nothing`: none), and whether
stand-ins cut own code (`own_cut`). Unit that always throws on stand-ins gives no verdict (`verdict` false), only its
blind spot. Method store entry of unit keeps record (`record_bytes`), so stored unit needs no typed code.
"""
struct UnitVerdict
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

"""Call facts of `root` with code in `run`, with spans from `span_of` (`root_calls!`)."""
function unit_calls!(run::Run, root::Variant, span_of::Function)::UnitCalls
    lines, found = run.codes[root].lines, UnitCalls()
    for (index, record) in root_calls!(run, root)
        fact = CallSummary(span_of(index), record...)
        push!(found, (lines[index], fact.span) => fact)
    end
    return found
end

"""Verdict record of root unit `typed` with variant `root` in solved `run`."""
function unit_verdict!(run::Run, typed::TypedCode, root::Variant)::UnitVerdict
    own_cut = !isempty(typed.cuts)
    # Unit that always throws on stand-ins shows no behavior of declared signature.
    typed.result === Union{} && return UnitVerdict(
        false, Access[], Access[], BlindAccess[], BlindAccess[], Place.Type[], UnguardedHold[], UnitCalls(),
        [BlindSpot("always throws on stand-ins", typed.site.span)], false, nothing, own_cut,
    )
    summary = root_summary!(run, root)
    span_of(cause::Integer)::Span = cause_span(typed, run.codes[root], cause)
    kind_of(place::Place.Type)::EffectKind.T = path_kind(run.codes[root].ir, place)
    writes, blind_writes = unit_accesses(summary.writes, span_of, typed.provenance)
    held_writes, held_blind = lock_writes(summary, span_of, kind_of)
    unguarded, spots = unguarded_holds(summary, span_of)
    reads, blind_reads = unit_accesses(summary.reads, span_of, typed.provenance)
    cut = summary.cut ? cut_span(run, typed, root) : nothing
    return UnitVerdict(
        true, [writes; held_writes], reads, [blind_writes; held_blind], blind_reads, result_aliases(summary), unguarded,
        unit_calls!(run, root, span_of), spots, summary.closed_world, cut, own_cut,
    )
end

"""`record` with call facts `calls`."""
with_calls(record::UnitVerdict, calls::UnitCalls)::UnitVerdict = UnitVerdict((name === :calls ? calls : getfield(record, name) for name in fieldnames(UnitVerdict))...)

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
loaded_callee(@nospecialize(stored::Any), world::UInt)::Callee.Type = stored isa Symbol ? Callee.Builtin(getfield(Core.Intrinsics, stored)) : stored isa Vector{Type} ? methods_callee(Method[method_of(signature, world) for signature in stored]) : stored::Callee.Type

"""Method of `world` whose signature is `signature`; other method or none throws."""
function method_of(signature::Type, world::UInt)::Method
    method = Base._which(signature; world).method
    method.sig == signature || throw(ArgumentError("method store names method $signature, which world $world lacks"))
    return method
end

"""Call summary `fact` with callee `callee`."""
with_callee(fact::CallSummary, callee::Callee.Type)::CallSummary = CallSummary((name === :callee ? callee : getfield(fact, name) for name in fieldnames(CallSummary))...)

"""Call facts of unit as method store keeps them: fact with open callee, and its callee (`stored_callee`)."""
const StoredCalls = Vector{Tuple{Tuple{Int, Span}, CallSummary, Any}}

"""Bytes of unit `record` for method store entry (`Inference.Entry`); `nothing` marks unit without code."""
function record_bytes(record::Union{Nothing, UnitVerdict})::Vector{UInt8}
    isnothing(record) && return serialized(nothing)
    calls = StoredCalls([(key, with_callee(fact, Callee.Open()), stored_callee(fact.callee)) for (key, fact) in record.calls])
    return serialized((with_calls(record, UnitCalls()), calls))
end

"""
Unit record that method store entry keeps in `bytes` (`record_bytes`); callees come back in `world`. `nothing` for unit
without code. Entry without record throws: `effects` run infers such unit instead.
"""
function unit_record(bytes::AbstractVector{UInt8}, world::UInt)::Union{Nothing, UnitVerdict}
    isempty(bytes) && throw(ArgumentError("method store entry keeps no effects record; effects run must infer its unit"))
    stored = deserialize(IOBuffer(bytes))::Union{Nothing, Tuple{UnitVerdict, StoredCalls}}
    isnothing(stored) && return nothing
    record, calls = stored
    return with_calls(record, UnitCalls([key => with_callee(fact, loaded_callee(callee, world)) for (key, fact, callee) in calls]))
end

"""
Effects record of each unit in inference order, with its method: typed unit takes its record in `fresh`, stored unit
(`Units.stored`) its record in `stored`. Order keeps first cause per access (`worst`), as run that infers all.
"""
function ordered_records(units::Units, fresh::AbstractVector{Union{Nothing, T}}, stored::AbstractVector{Union{Nothing, T}})::Vector{Pair{Method, Union{Nothing, T}}} where {T}
    positions = [[(index, 0) for index in eachindex(units.typed)]; [(unit.position, 1) for unit in units.stored]]
    methods = Method[[typed.site.method for typed in units.typed]; [unit.site.method for unit in units.stored]]
    records = Union{Nothing, T}[fresh; stored]
    return [methods[index] => records[index] for index in sortperm(positions)]
end
