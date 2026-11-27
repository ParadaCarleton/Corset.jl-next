using Serialization: deserialize

"""Call facts of one unit, each keyed by source statement and span, in statement order."""
const UnitCalls = Vector{Pair{Tuple{Int, Span}, CallFact}}

"""
Effects of one unit for facts of its method (`effects.md`, Units and IR): accesses with cause spans, result aliases,
holds throws skip, call facts, loop writes (F48), self-alias calls (F50), stateful reuses (F51), index facts (F36), arrays it allocates (`lifecycle.md`), blind spots, compiler proof of no write (`effect_free`),
whether return gives new value (`new_result`, `returns_new`), and span of first stand-in cut (`nothing`: none). Unit that always throws on stand-ins gives no verdict (`verdict` false), only its
blind spot. Method store entry of unit keeps record (`record_bytes`), so stored unit needs no typed code.
"""
struct UnitEffects
    verdict::Bool
    writes::Vector{Access}
    reads::Vector{Access}
    aliases::Vector{Place.Type}
    unguarded::Vector{UnguardedHold}
    calls::UnitCalls
    loop_writes::Vector{LoopWrite}
    self_aliases::Vector{SelfAlias}
    stateful_reuses::Vector{StatefulReuse}
    indices::IndexFacts
    arrays::Vector{ArrayLife}
    spots::Vector{BlindSpot}
    effect_free::Bool
    new_result::Bool
    cut::Union{Nothing, Span}
end

"""`record` with call facts `calls`."""
with_calls(record::UnitEffects, calls::UnitCalls)::UnitEffects = UnitEffects((name === :calls ? calls : getfield(record, name) for name in fieldnames(UnitEffects))...)

"""`fact` with callee `callee`."""
with_callee(fact::CallFact, callee::Callee.Type)::CallFact = CallFact((name === :callee ? callee : getfield(fact, name) for name in fieldnames(CallFact))...)

"""Call facts of unit as method store keeps them: fact with open callee, and its callee (`stored_callee`)."""
const StoredCalls = Vector{Tuple{Tuple{Int, Span}, CallFact, Any}}

"""
Bytes of unit `record` and engine `verdict` for method store entry (`Inference.Entry`); `nothing` for both marks unit
without record. One record without other throws: both tiers judge same units.
"""
function record_bytes(record::Union{Nothing, UnitEffects}, verdict::Union{Nothing, Summaries.UnitVerdict})::Vector{UInt8}
    isnothing(record) == isnothing(verdict) || throw(ArgumentError(isnothing(record) ? "unit has engine verdict without name record" : "unit has name record without engine verdict"))
    isnothing(record) && return serialized(nothing)
    calls = StoredCalls([(key, with_callee(fact, Callee.Open()), stored_callee(fact.callee)) for (key, fact) in record.calls])
    return serialized((with_calls(record, UnitCalls()), calls, Summaries.record_bytes(verdict)))
end

"""
Unit record and engine verdict that method store entry keeps in `bytes` (`record_bytes`); callees come back in `world`.
`nothing` for unit without record. Entry without record throws: `effects` run infers such unit instead.
"""
function unit_record(bytes::AbstractVector{UInt8}, world::UInt)::Union{Nothing, Tuple{UnitEffects, Summaries.UnitVerdict}}
    isempty(bytes) && throw(ArgumentError("method store entry keeps no effects record; effects run must infer its unit"))
    stored = deserialize(IOBuffer(bytes))::Union{Nothing, Tuple{UnitEffects, StoredCalls, Vector{UInt8}}}
    isnothing(stored) && return nothing
    record, calls, verdict = stored
    loaded = with_calls(record, UnitCalls([key => with_callee(fact, loaded_callee(callee, world)) for (key, fact, callee) in calls]))
    return loaded, something(Summaries.unit_record(verdict, world))
end
