# Stateful reuse of name tier (F51; `phase5.md`, row 7): iterator started twice, or escaping after start.

"""Types whose every iteration starts from first element (`phase5.md`, F51 multi-pass types)."""
const MULTI_PASS = Union{AbstractArray, AbstractDict, AbstractSet, AbstractString, Tuple, NamedTuple, Number, AbstractChar}

"""Functions whose result iterates operands together: code that consumes it starts each operand, `zip(itr, itr)` twice."""
const JOINT_FUNCTIONS = Base.IdSet{Any}(Any[zip, Iterators.product])

"""
Iterator event of unit: statement `index`, operand path `position` (operand of call, then operands of `zip` it
consumes), IR `operand`, whether it escapes (`false`: starts iteration), and certainty: generic `isempty` among other
`isempty` methods gives `possible` start.
"""
struct IteratorEvent
    index::Int
    position::Vector{Int}
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
Iterators package method starts twice or lets escape after start, in unit `walk` of `method` with `spans` of its IR
statements. Later event pairs with first earlier event of same object on one path; two escapes make no pair.
"""
function stateful_reuses(walk::Walk, method::Method, spans::AbstractVector{Span})::Vector{StatefulReuse}
    Base.require_one_based_indexing(spans)
    # Escaping value can hold iterator (returned tuple), so only start needs type of either kind.
    events = IteratorEvent[event for index in 1:length(walk.ir.stmts) for event in iterator_events(walk, index) if event.escapes || either_pass(operand_type(walk, event.operand))]
    found, following = StatefulReuse[], Dict{Tuple{Int, Vector{Int}}, Set{Int}}()
    any(event -> !event.escapes, events) || return found
    for later in events, earlier in events
        (earlier.escapes && later.escapes) && continue
        # Escaping `zip` result and starts of its operands name one operand.
        nested(earlier, later) && continue
        started, other = later.escapes ? (earlier, later) : (later, earlier)
        relation = same_iterator(walk, started.operand, other.operand, other.escapes)
        isnothing(relation) && continue
        renew, reload = renewal(walk, started.operand)
        if !runs_before(walk, following, earlier, later, union(renew, reload))
            # Load of unchanged container and key can give same iterator again.
            runs_before(walk, following, earlier, later, renew) || continue
            relation = Confidence.possible
        end
        confidence = max(something(relation), earlier.confidence, later.confidence)
        push!(found, StatefulReuse(spans[earlier.index], spans[later.index], earlier.escapes, later.escapes, earlier === later, iterator_text(walk, method, started.operand), confidence))
        break
    end
    return unique!(found)
end

"""Whether events `one` and `other` are one statement and operand path of one starts with path of other."""
function nested(one::IteratorEvent, other::IteratorEvent)::Bool
    one.index == other.index || return false
    shorter = min(length(one.position), length(other.position))
    return length(one.position) != length(other.position) && one.position[1:shorter] == other.position[1:shorter]
end

"""
Iterator events of statement `index` of `walk`: returned value escapes; call starts or lets operands escape. Code that
consumes `zip` result, or lets it escape to caller, starts each zipped operand (`joint_starts!`).
"""
function iterator_events(walk::Walk, index::Integer)::Vector{IteratorEvent}
    statement, found = walk.ir.stmts[index][:stmt], IteratorEvent[]
    if statement isa Core.ReturnNode
        isdefined(statement, :val) && push!(found, IteratorEvent(index, [1], statement.val, true, Confidence.definite))
    elseif statement isa Expr && statement.head === :call
        callee, operands = call_parts(walk, statement)
        isnothing(operands) && return found
        append!(found, (IteratorEvent(index, [position], operands[position], false, Confidence.definite) for position in started_positions(walk, callee, operands)))
        if isempty(found) && callee === isempty && length(operands) == 1
            confidence = isempty_start(walk, operand_type(walk, operands[1]))
            isnothing(confidence) || push!(found, IteratorEvent(index, [1], operands[1], false, confidence))
        end
        append!(found, (IteratorEvent(index, [position], operands[position], true, Confidence.definite) for position in escaped_positions(walk, callee, operands)))
    end
    foreach(event -> joint_starts!(found, walk, event.index, event.position, event.operand), copy(found))
    return found
end

"""Push onto `found` starts of operands that `zip` result `operand` of `walk` iterates, at statement `index` and path `position`."""
function joint_starts!(found::AbstractVector{IteratorEvent}, walk::Walk, index::Integer, position::AbstractVector{<:Integer}, @nospecialize(operand::Any))::Nothing
    parts = joint_operands(walk, operand)
    isnothing(parts) && return nothing
    for (inner, part) in enumerate(parts)
        path = Int[position; inner]
        push!(found, IteratorEvent(index, path, part, false, Confidence.definite))
        joint_starts!(found, walk, index, path, part)
    end
    return nothing
end

"""Operands of `zip` or `Iterators.product` call that IR `operand` of `walk` is, after `π` nodes; `nothing` for other value."""
function joint_operands(walk::Walk, @nospecialize(operand::Any))::Union{Nothing, Vector{Any}}
    root = underlying(walk, operand)
    root isa Core.SSAValue || return nothing
    statement = walk.ir.stmts[root.id][:stmt]
    statement isa Expr || return nothing
    statement.head === :call || return nothing
    callee, operands = call_parts(walk, statement)
    return callee in JOINT_FUNCTIONS ? operands : nothing
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
Blocks whose next run gives new object for started IR `operand` of `walk` (`renew`), and blocks of loads it comes through
(`reload`): load of unchanged container and key gives same object again. Argument, global, constant and object at one
place (`object_place`) renew nothing.
"""
function renewal(walk::Walk, @nospecialize(operand::Any))::Tuple{Set{Int}, Set{Int}}
    renew, reload = Set{Int}(), Set{Int}()
    value = operand_value(walk, operand)
    (!value.fresh && length(value.places) == 1 && object_place(only(value.places))) && return renew, reload
    pending, seen = Any[operand], Set{Int}()
    while !isempty(pending)
        current = underlying(walk, pop!(pending))
        current isa Core.SSAValue || continue
        current.id in seen && continue
        push!(seen, current.id)
        block = CC.block_for_inst(walk.ir.cfg, current.id)
        loaded = loaded_operands(walk, walk.ir.stmts[current.id][:stmt])
        if isnothing(loaded)
            push!(renew, block)
        else
            push!(reload, block)
            append!(pending, loaded)
        end
    end
    return renew, reload
end

"""Container and key operands of load statement (`getindex`, field load, `first`) in `walk`; `nothing` for other statement."""
function loaded_operands(walk::Walk, @nospecialize(statement::Any))::Union{Nothing, Vector{Any}}
    statement isa Expr || return nothing
    statement.head === :call || return nothing
    callee, operands = call_parts(walk, statement)
    (isnothing(operands) || isempty(operands)) && return nothing
    # `T[a, b]` is array literal: new object.
    loads = callee in LOAD_BUILTINS || callee in (getproperty, first, last, only) || (callee === getindex && !(operand_type(walk, operands[1]) <: Type))
    return loads ? operands : nothing
end

"""
Whether event `later` can run after event `earlier` of `walk` on one path that enters no block of `avoid`: later
statement in same block, later operand path of same statement, or block that successors of earlier block reach.
`following` caches reached blocks per block and avoided blocks.
"""
function runs_before(walk::Walk, following::AbstractDict{<:Tuple{Integer, AbstractVector{<:Integer}}, <:AbstractSet{<:Integer}}, earlier::IteratorEvent, later::IteratorEvent, avoid::AbstractSet{<:Integer})::Bool
    cfg = walk.ir.cfg
    block, other = CC.block_for_inst(cfg, earlier.index), CC.block_for_inst(cfg, later.index)
    (block == other && (later.index, later.position) > (earlier.index, earlier.position)) && return true
    exits = next -> filter(successor -> !(successor in avoid), cfg.blocks[next].succs)
    # Block in loop reaches itself, so start inside loop runs again after itself.
    return other in get!(() -> reached(exits(block), exits), following, (block, sort!(collect(Int, avoid))))
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

"""Whether IR value `holder` of `walk` is IR value `target`, or holds it through statements that hold operands (`held_operands`)."""
function holds_operand(walk::Walk, @nospecialize(holder::Any), @nospecialize(target::Any))::Bool
    pending, seen = Any[holder], Set{Int}()
    while !isempty(pending)
        current = underlying(walk, pop!(pending))
        current === target && return true
        current isa Core.SSAValue || continue
        current.id in seen && continue
        push!(seen, current.id)
        append!(pending, held_operands(walk, walk.ir.stmts[current.id][:stmt]))
    end
    return false
end

"""
Operands that result of IR `statement` of `walk` holds: `new`, tuple, `convert`, `zip` and constructor. Container
constructor (`Dict(pairs)`) holds elements of its iterator operand, not iterator.
"""
function held_operands(walk::Walk, @nospecialize(statement::Any))::Vector{Any}
    statement isa Expr || return Any[]
    statement.head === :new && return statement.args[2:end]
    statement.head === :call || return Any[]
    callee, operands = call_parts(walk, statement)
    holding = callee === Core.tuple || callee === convert || callee in JOINT_FUNCTIONS || (callee isa Type && !(callee <: MULTI_PASS))
    return (holding && !isnothing(operands)) ? operands : Any[]
end

"""Source text of iterator `operand` of `walk` in `method`: its one caller place, else `nothing`."""
function iterator_text(walk::Walk, method::Method, @nospecialize(operand::Any))::Union{Nothing, String}
    value = operand_value(walk, operand)
    (value.fresh || length(value.places) != 1) && return nothing
    return place_text(method, only(value.places))
end
