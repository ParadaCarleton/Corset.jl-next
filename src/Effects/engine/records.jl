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

"""Whether `statement` builds value that holds its operands: tuple, new object (closure) or narrowed copy."""
function holds_operands(@nospecialize(statement::Any))::Bool
    statement isa Core.PiNode && return true
    statement isa Expr || return false
    statement.head in (:new, :splatnew) && return true
    return statement.head === :call && statement.args[1] in (GlobalRef(Core, :tuple), Core.tuple)
end

"""
Whether constant `value` holds `TaskLocalRNG` in field, at most `depth` levels down: closure or tuple that captured
RNG. `TaskLocalRNG` is singleton, so inference folds closure over RNG argument to constant.
"""
function holds_task_rng(@nospecialize(value::Any), depth::Integer)::Bool
    (depth == 0 || value isa Type || value isa Module) && return false
    for index in 1:nfields(value)
        isdefined(value, index) || continue
        field = getfield(value, index)
        (field isa Random.TaskLocalRNG || holds_task_rng(field, depth - 1)) && return true
    end
    return false
end

"""
Arguments at `positions` that each call statement of `code` passes: argument itself, tuple or new object (closure)
built from it, or constant that holds `TaskLocalRNG` (`holds_task_rng`).
"""
function passed_arguments(code::Code, positions::AbstractVector{<:Integer})::Dict{Int, Set{Int}}
    held, passed = Dict{Int, Set{Int}}(), Dict{Int, Set{Int}}()
    for index in 1:length(code.ir.stmts)
        statement, carried = code.ir.stmts[index][:stmt], Set{Int}()
        for reference in CC.userefs(statement)
            operand = reference[]
            operand isa Core.Argument && operand.n in positions && push!(carried, operand.n)
            operand isa Core.SSAValue && union!(carried, get(held, operand.id, Set{Int}()))
            operand isa Union{Core.Argument, Core.SSAValue, GlobalRef, Expr} && continue
            # Bare `TaskLocalRNG()` constant is `default_rng()`; constant that holds it captured RNG argument.
            holds_task_rng(operand isa QuoteNode ? operand.value : operand, 3) && union!(carried, positions)
        end
        isempty(carried) && continue
        isnothing(code.outcomes[index]) || (passed[index] = carried)
        holds_operands(statement) && (held[index] = carried)
    end
    return passed
end

"""Whether `summary` reads or writes default RNG."""
reaches_default_rng(summary::Summary)::Bool = any(((_, _, kind),) -> kind == EffectKind.default_rng, Iterators.flatten((keys(summary.writes), keys(summary.reads))))

"""Whether call statement `index` of `code` in `run` reaches default RNG: callee summary does, or builtin gets `Task`."""
function reaches_default_rng(run::Run, code::Code, index::Integer)::Bool
    any(callee -> reaches_default_rng(run.summaries[callee]), code.callees[index]) && return true
    outcome = code.outcomes[index]
    isnothing(outcome) && return false
    return @match something(outcome) begin
        Outcome.Builtin(_, operands) => any(operand -> operand_type(code.ir, operand) <: Task, operands)
        _ => false
    end
end

"""Whether `method` declares argument at `position` (1 is first after callee) with type that takes any RNG."""
takes_any_rng(method::Method, position::Integer)::Bool = Random.AbstractRNG <: argument_type(method, position)::Type

"""
Arguments of root `root` that hold default RNG by caller choice (`engine.md`, Effect kinds): `TaskLocalRNG` where
method declares type that takes any RNG. Empty unless each call that reaches default RNG gets one of them.
"""
function chosen_rng_arguments(run::Run, root::Variant)::Vector{Int}
    instance, code = first(root), run.codes[root]
    types = tuple_parameters(instance.specTypes)
    method = instance.def::Method
    # Method that declares `TaskLocalRNG` chose default RNG itself.
    positions = [position + 1 for position in rng_positions(method) if position + 1 <= length(types) && types[position + 1] === Random.TaskLocalRNG && takes_any_rng(method, position)]
    isempty(positions) && return positions
    passed = passed_arguments(code, positions)
    reaching = filter(index -> reaches_default_rng(run, code, index), eachindex(code.outcomes))
    all(index -> haskey(passed, index), reaching) || return Int[]
    return sort!(collect(reduce(union, (passed[index] for index in reaching); init = Set{Int}())))
end

"""
`accesses` with each default RNG access moved to argument at each of `positions` (`chosen_rng_arguments`): kind stays
default RNG, since draw still touches `Task` state; `possible` when several arguments share it.
"""
function chosen_rng(accesses::AbstractVector{Access}, positions::AbstractVector{<:Integer})::Vector{Access}
    isempty(positions) && return accesses
    moved(access::Access, position::Integer)::Access =
        Access(Place.At(Root.Parameter(position), NO_STEPS), false, EffectKind.default_rng, length(positions) == 1 ? access.confidence : Confidence.possible, access.callback, access.cause)
    return [found for access in accesses for found in (access.kind == EffectKind.default_rng ? [moved(access, position) for position in positions] : [access])]
end

"""Verdict record of root unit `typed` with variant `root` in solved `run`."""
function unit_verdict!(run::Run, typed::TypedCode, root::Variant)::UnitVerdict
    own_cut = !isempty(typed.cuts)
    # Unit that always throws on stand-ins shows no behavior of declared signature.
    typed.result === Union{} && return UnitVerdict(
        false, Access[], Access[], BlindAccess[], BlindAccess[], Place.Type[], UnguardedHold[], UnitCalls(),
        [BlindSpot("always throws on stand-ins", typed.site.span)], false, nothing, own_cut,
    )
    summary, own = root_summary!(run, root), run.summaries[root]
    span_of(cause::Integer)::Span = cause_span(typed, run.codes[root], cause)
    kind_of(place::Place.Type)::EffectKind.T = path_kind(run.codes[root].ir, first(root).def::Method, place)
    writes, blind_writes = verdict_accesses(summary.writes, own.writes, span_of, typed.provenance)
    held_writes, held_blind = lock_writes(summary, span_of, kind_of)
    unguarded, spots = unguarded_holds(summary, span_of)
    reads, blind_reads = verdict_accesses(summary.reads, own.reads, span_of, typed.provenance)
    chosen = chosen_rng_arguments(run, root)
    cut = summary.cut ? cut_span(run, typed, root) : nothing
    return UnitVerdict(
        true, [chosen_rng(writes, chosen); held_writes], chosen_rng(reads, chosen), [blind_writes; held_blind], blind_reads, result_aliases(summary), unguarded,
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
