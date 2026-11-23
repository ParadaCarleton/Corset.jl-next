# Stateful reuse of name tier (F51; `phase5.md`, row 7): iterator started twice, or escaping after start.

"""Types whose every iteration starts from first element (`phase5.md`, F51 multi-pass types)."""
const MULTI_PASS = Union{AbstractArray, AbstractDict, AbstractSet, AbstractString, Tuple, NamedTuple, Number, AbstractChar}

"""Functions whose used result iterates operands together, so each operand starts: `zip(itr, itr)` starts `itr` twice."""
const JOINT_FUNCTIONS = Base.IdSet{Any}(Any[zip, Iterators.product])

"""
Iterator event of unit: statement `index`, operand `position` in call, IR `operand`, whether it escapes (`false`: starts
iteration), and certainty: generic `isempty` among other `isempty` methods gives `possible` start.
"""
struct IteratorEvent
    index::Int
    position::Int
    operand::Any
    escapes::Bool
    confidence::Confidence.T
end

"""
Whether iterator of `type` can be stateful or multi-pass, so second start depends on value: member of unknown kind, or
members of both kinds. `nothing` and `missing` members iterate nothing.
"""
function either_pass(@nospecialize(type::Any))::Bool
    kinds = Set{Union{Nothing, Bool}}()
    for member in Base.uniontypes(type)
        (member isa Type && !(member <: Union{Nothing, Missing})) && push!(kinds, pass_kind(member))
    end
    return nothing in kinds || length(kinds) > 1
end

"""
Kind of iterator of `type`: `true` for stateful iterator (`stateful_iterator`), `false` for `MULTI_PASS`, `Type` or one
concrete type, `nothing` when unknown. Restart of one kind is deliberate: `first(eachline(io))` skips header line.
"""
function pass_kind(type::Type)::Union{Nothing, Bool}
    stateful_iterator(Base.unwrap_unionall(type)) && return true
    (type <: MULTI_PASS || type <: Type || isconcretetype(type)) && return false
    return nothing
end

"""
Iterators package method starts twice or lets escape after start, in unit `walk` of `method` with `spans` and `uses`
(result used) of its IR statements. Later event pairs with first earlier event of same object on one path; two escapes
make no pair.
"""
function stateful_reuses(walk::Walk, method::Method, spans::AbstractVector{Span}, uses::AbstractVector{Bool})::Vector{StatefulReuse}
    Base.require_one_based_indexing(spans, uses)
    # Escaping value can hold iterator (returned tuple), so only start needs type of either kind.
    events = IteratorEvent[event for index in 1:length(walk.ir.stmts) for event in iterator_events(walk, index, uses[index]) if event.escapes || either_pass(operand_type(walk, event.operand))]
    found, following = StatefulReuse[], Dict{Tuple{Int, Int}, Set{Int}}()
    any(event -> !event.escapes, events) || return found
    for later in events, earlier in events
        (earlier.escapes && later.escapes) && continue
        started, other = later.escapes ? (earlier, later) : (later, earlier)
        relation = same_iterator(walk, started.operand, other.operand, other.escapes)
        isnothing(relation) && continue
        runs_before(walk, following, earlier, later, renewing_block(walk, started.operand)) || continue
        confidence = max(something(relation), earlier.confidence, later.confidence)
        push!(found, StatefulReuse(spans[earlier.index], spans[later.index], earlier.escapes, later.escapes, earlier === later, iterator_text(walk, method, started.operand), confidence))
        break
    end
    return unique!(found)
end

"""
Iterator events of statement `index` of `walk` whose result code uses when `used`: returned value escapes; call starts or
lets operands escape. Discarded `zip` iterates nothing.
"""
function iterator_events(walk::Walk, index::Integer, used::Bool)::Vector{IteratorEvent}
    statement = walk.ir.stmts[index][:stmt]
    statement isa Core.ReturnNode && return isdefined(statement, :val) ? [IteratorEvent(index, 1, statement.val, true, Confidence.definite)] : IteratorEvent[]
    statement isa Expr || return IteratorEvent[]
    statement.head === :call || return IteratorEvent[]
    callee, operands = call_parts(walk, statement)
    isnothing(operands) && return IteratorEvent[]
    found = IteratorEvent[IteratorEvent(index, position, operands[position], false, Confidence.definite) for position in started_positions(walk, callee, operands)]
    if isempty(found) && callee === isempty && length(operands) == 1
        confidence = isempty_start(walk, operand_type(walk, operands[1]))
        isnothing(confidence) || push!(found, IteratorEvent(index, 1, operands[1], false, confidence))
    elseif used && callee in JOINT_FUNCTIONS
        append!(found, (IteratorEvent(index, position, operands[position], false, Confidence.definite) for position in eachindex(operands)))
    end
    append!(found, (IteratorEvent(index, position, operands[position], true, Confidence.definite) for position in escaped_positions(walk, callee, operands)))
    return found
end

"""
Positions of operands call of `callee` lets escape: stored values of store builtins, operands `!` call does not write,
and operands of package function or type, which code outside method can iterate.
"""
function escaped_positions(walk::Walk, @nospecialize(callee::Any), operands::AbstractVector{Any})::Vector{Int}
    Base.require_one_based_indexing(operands)
    (callee in STORE_BUILTINS || callee in GLOBAL_BUILTINS) && return collect(2:length(operands))
    kept = if bang_function(callee)
        written_position(walk, callee, operands)
    elseif package_callee(walk, callee)
        0
    else
        return Int[]
    end
    return Int[position for position in eachindex(operands) if position != kept && !callable(walk, operands[position])]
end

"""Whether `callee` is function or type of package modules of `walk`."""
package_callee(walk::Walk, @nospecialize(callee::Any))::Bool = (callee isa Function || callee isa DataType || callee isa UnionAll) && parentmodule(callee) in walk.modules

"""
Block whose next run gives new object for started IR `operand` of `walk`: block that defines its underlying IR value.
Zero for argument, global, and object at one place (`object_place`): they stay one object across loop passes.
"""
function renewing_block(walk::Walk, @nospecialize(operand::Any))::Int
    value = operand_value(walk, operand)
    (!value.fresh && length(value.places) == 1 && object_place(only(value.places))) && return 0
    root = underlying(walk, operand)
    return root isa Core.SSAValue ? CC.block_for_inst(walk.ir.cfg, root.id) : 0
end

"""
Whether event `later` can run after event `earlier` of `walk` on one path that does not enter block `avoid`: later
statement in same block, later operand of same call, or block that successors of earlier block reach. `following`
caches reached blocks per block and avoided block.
"""
function runs_before(walk::Walk, following::AbstractDict{<:Tuple{Integer, Integer}, <:AbstractSet{<:Integer}}, earlier::IteratorEvent, later::IteratorEvent, avoid::Integer)::Bool
    cfg = walk.ir.cfg
    block, other = CC.block_for_inst(cfg, earlier.index), CC.block_for_inst(cfg, later.index)
    (block == other && (later.index, later.position) > (earlier.index, earlier.position)) && return true
    exits = next -> filter(!=(avoid), cfg.blocks[next].succs)
    # Block in loop reaches itself, so start inside loop runs again after itself.
    return other in get!(() -> reached(exits(block), exits), following, (block, avoid))
end

"""
Certainty that started IR operand `object` and IR operand `other` of `walk` are one iterator. One IR value, or escaping
`other` (`holds`) that holds it (`holds_operand`), gives `definite`. Else object needs places that each name one object
(`object_place`): one same place, or one place that escaping `other` holds, gives `definite`; places that `other` holds
or can be at give `possible`.
"""
function same_iterator(walk::Walk, @nospecialize(object::Any), @nospecialize(other::Any), holds::Bool)::Union{Nothing, Confidence.T}
    root = underlying(walk, object)
    (root === underlying(walk, other) || (holds && holds_operand(walk, other, root))) && return Confidence.definite
    value = operand_value(walk, object)
    (value.fresh || isempty(value.places) || !all(object_place, value.places)) && return nothing
    single = length(value.places) == 1
    (single && same_place(walk, object, other)) && return Confidence.definite
    (holds && issubset(value.places, held(operand_value(walk, other)))) && return single ? Confidence.definite : Confidence.possible
    return overlap(walk, other, object, false) == Overlap.exact ? Confidence.possible : nothing
end

"""
Whether IR value `holder` of `walk` is IR value `target`, or tuple, `new`, constructor or `convert` result that holds it.
Container constructor (`Dict(pairs)`) holds elements of its iterator operand, not iterator. Operands come before their
statement, so search ends.
"""
function holds_operand(walk::Walk, @nospecialize(holder::Any), @nospecialize(target::Any))::Bool
    holder = underlying(walk, holder)
    holder === target && return true
    holder isa Core.SSAValue || return false
    statement = walk.ir.stmts[holder.id][:stmt]
    statement isa Expr || return false
    statement.head === :new && return any(operand -> holds_operand(walk, operand, target), statement.args[2:end])
    statement.head === :call || return false
    callee, operands = call_parts(walk, statement)
    holding = callee === Core.tuple || callee === convert || (callee isa Type && !(callee <: MULTI_PASS))
    (holding && !isnothing(operands)) || return false
    return any(operand -> holds_operand(walk, operand, target), operands)
end

"""Source text of iterator `operand` of `walk` in `method`: its one caller place, else `nothing`."""
function iterator_text(walk::Walk, method::Method, @nospecialize(operand::Any))::Union{Nothing, String}
    value = operand_value(walk, operand)
    (value.fresh || length(value.places) != 1) && return nothing
    return place_text(method, only(value.places))
end
