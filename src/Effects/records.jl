using Serialization: deserialize

"""Call facts of one unit, each keyed by source statement and span, in statement order."""
const UnitCalls = Vector{Pair{Tuple{Int, Span}, CallFact}}

"""
Effects of one unit for facts of its method (`effects.md`, Units and IR): accesses with cause spans, result aliases,
holds throws skip, call facts, blind spots, compiler proof of no write (`effect_free`), and span of first stand-in cut
(`nothing`: none). Unit that always throws on stand-ins gives no verdict (`verdict` false), only its blind spot. Method
store entry of unit keeps record (`record_bytes`), so stored unit needs no typed code.
"""
struct UnitEffects
    verdict::Bool
    writes::Vector{Access}
    reads::Vector{Access}
    aliases::Vector{Place.Type}
    unguarded::Vector{UnguardedHold}
    calls::UnitCalls
    spots::Vector{BlindSpot}
    effect_free::Bool
    cut::Union{Nothing, Span}
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
loaded_callee(@nospecialize(stored::Any), world::UInt)::Callee.Type = stored isa Symbol ? Callee.Builtin(getfield(Core.Intrinsics, stored)) : stored isa Vector{Type} ? methods_callee(Method[method_of(signature, world) for signature in stored]) : stored::Callee.Type

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

"""Bytes of unit `record` for method store entry (`Inference.Entry`); `nothing` marks a unit without a record."""
function record_bytes(record::Union{Nothing, UnitEffects})::Vector{UInt8}
    isnothing(record) && return serialized(nothing)
    calls = StoredCalls([(key, with_callee(fact, Callee.Open()), stored_callee(fact.callee)) for (key, fact) in record.calls])
    return serialized((with_calls(record, UnitCalls()), calls))
end

"""
Unit record that method store entry keeps in `bytes` (`record_bytes`); callees come back in `world`. `nothing` for unit
without a record. Entry without record throws: `effects` run infers such unit instead.
"""
function unit_record(bytes::Vector{UInt8}, world::UInt)::Union{Nothing, UnitEffects}
    isempty(bytes) && throw(ArgumentError("method store entry keeps no effects record; effects run must infer its unit"))
    stored = deserialize(IOBuffer(bytes))::Union{Nothing, Tuple{UnitEffects, StoredCalls}}
    isnothing(stored) && return nothing
    record, calls = stored
    return with_calls(record, UnitCalls([key => with_callee(fact, loaded_callee(callee, world)) for (key, fact, callee) in calls]))
end
