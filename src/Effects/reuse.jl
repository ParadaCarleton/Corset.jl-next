# Stateful reuse of name tier (F51; `phase5.md`, row 7): iterator started twice, or escaping after start.

"""Types whose every iteration starts from first element (`phase5.md`, F51 multi-pass types)."""
const MULTI_PASS = Union{AbstractArray, AbstractDict, AbstractSet, AbstractString, Tuple, NamedTuple, Pair, Number, AbstractChar}

"""Functions whose result iterates operands together: code that consumes it starts each operand, `zip(itr, itr)` twice."""
const JOINT_FUNCTIONS = Base.IdSet{Any}(Any[zip, Iterators.product])

"""Blind spot cause of reuse through consuming call that only specialized method serves: its body decides start."""
const SPECIALIZED_START = "start through specialized method"

"""Blind spot cause of reuse of `blind` kind: struct parameter inside field type (`items::Vector{T}`), so `iterate` body decides kind."""
const NESTED_PARAMETER = "struct parameter inside field type"

"""
Iterator event of unit: statement `index`, operand path `position` (operand of call, then operands of `zip` it
consumes), IR `operand`, whether it escapes (`false`: starts iteration), certainty (generic `isempty` among other
`isempty` methods gives `possible` start), and whether only specialized method can start it (`specialized`).
"""
struct IteratorEvent
    index::Int
    position::Vector{Int}
    operand::Any
    escapes::Bool
    confidence::Confidence.T
    specialized::Bool
end

"""
Kind of iterator that type gives: `multi` restarts at each start, `stateful` advances, `open` depends on value (finding),
`blind` depends on `iterate` body that Corset does not read (blind spot).
"""
@enumx Pass multi stateful open blind

# corset: allow bang-convention -- memo of type answers; result never changes
"""
Kind of iterator of `type`, joined over union members; `nothing` and `missing` iterate nothing. Members of both kinds,
or `open` member, give `open`; else `blind` member gives `blind`. Type variable takes kind of its bound. `memo` holds
kinds of types this traversal met: bound that parameters share answers once.
"""
function pass_kind(@nospecialize(type::Any), memo::IdDict{Any, Pass.T} = IdDict{Any, Pass.T}())::Pass.T
    haskey(memo, type) && return memo[type]
    kinds = Set{Pass.T}()
    for member in Base.uniontypes(type)
        if member isa TypeVar
            push!(kinds, pass_kind(member.ub, memo))
        elseif member isa Type && !(member <: Union{Nothing, Missing})
            push!(kinds, member_kind(member, memo))
        end
    end
    kind = Pass.open in kinds || (Pass.multi in kinds && Pass.stateful in kinds) ? Pass.open : Pass.blind in kinds ? Pass.blind : Pass.stateful in kinds ? Pass.stateful : Pass.multi
    memo[type] = kind
    return kind
end

"""
Kind of iterator of one type: `stateful_iterator` is `stateful`; `MULTI_PASS`, `Type` and concrete type are `multi`;
abstract type is `open`. Struct family (`Bag{T} where T`) takes kinds of parameter bounds: `open` bound gives `open` as
field (`inner::T`: iteration can pass to field) and `blind` inside field type (`items::Vector{T}`); `blind` bound gives
`blind`. Restart of one kind is deliberate. Recursion ends: bound names only types defined before its family.
"""
function member_kind(type::Type, memo::IdDict{Any, Pass.T})::Pass.T
    body = Base.unwrap_unionall(type)
    stateful_iterator(body) && return Pass.stateful
    (type <: MULTI_PASS || type <: Type || isconcretetype(type)) && return Pass.multi
    body isa DataType || return Pass.open
    # Unbounded variable (`NamedTuple{K, V} where {K, V}`) fails subtype test that family name passes.
    body.name.wrapper <: MULTI_PASS && return Pass.multi
    (isstructtype(body) && !isabstracttype(body)) || return Pass.open
    count = Base.datatype_fieldcount(body)
    isnothing(count) && return Pass.open
    kind = Pass.multi
    for parameter in body.parameters
        parameter isa TypeVar || continue
        bound = pass_kind(parameter.ub, memo)
        bound in (Pass.open, Pass.blind) || continue
        for index in 1:count
            field = fieldtype(body, index)
            Base.has_typevar(field, parameter) || continue
            (bound === Pass.open && holds_directly(field, parameter)) && return Pass.open
            kind = Pass.blind
        end
    end
    return kind
end

"""Whether field type `field` is `parameter`, or union holding it: iteration can pass to field itself."""
holds_directly(@nospecialize(field::Any), parameter::TypeVar)::Bool = field === parameter || (field isa Union && (holds_directly(field.a, parameter) || holds_directly(field.b, parameter)))

"""
Kind of iterator that start of IR `operand` in `walk` meets (`pass_kind`): result of `iterate` is `nothing` or tuple
by protocol, though inference can give `Any`.
"""
start_kind(walk::Walk, @nospecialize(operand::Any))::Pass.T = iterate_result(walk, operand) ? Pass.multi : pass_kind(iterator_type(walk, operand))

"""
Type of IR `operand` in `walk`, narrowed by declared type of field it loads: struct stand-in can leave field type open
(`Any`), though struct declares it (`NamedTuple{K, V}`).
"""
function iterator_type(walk::Walk, @nospecialize(operand::Any))::Any
    type, value = operand_type(walk, operand), underlying(walk, operand)
    value isa Core.SSAValue || return type
    statement = walk.ir.stmts[value.id][:stmt]
    statement isa Expr || return type
    statement.head === :call || return type
    callee, operands = call_parts(walk, statement)
    isnothing(operands) && return type
    length(operands) == 2 || return type
    object = operand_type(walk, operands[1])
    # Field load: `getfield`, or `getproperty` that only Base default method serves.
    field = callee === getfield || (callee === getproperty && generic_match(walk, Tuple{typeof(getproperty), object, Symbol}, Tuple{typeof(getproperty), Any, Symbol}) == Confidence.definite)
    field || return type
    declared = declared_field(object, constant_value(walk, operands[2]))
    return isnothing(declared) ? type : typeintersect(type, something(declared))
end

"""Declared type of field `name` of struct family of `object`, over all its parameters; `nothing` for tuple or unknown field."""
function declared_field(@nospecialize(object::Any), @nospecialize(name::Any))::Union{Nothing, Some{Any}}
    name isa Union{Symbol, Int} || return nothing
    body = Base.unwrap_unionall(object)
    body isa DataType || return nothing
    (isabstracttype(body) || body <: Union{Tuple, NamedTuple}) && return nothing
    wrapper = body.name.wrapper
    generic = Base.unwrap_unionall(wrapper)::DataType
    name isa Symbol && !hasfield(generic, name) && return nothing
    name isa Int && !(1 <= name <= fieldcount(generic)) && return nothing
    return Some{Any}(Base.rewrap_unionall(fieldtype(generic, name), wrapper))
end

"""Whether IR `operand` of `walk` is result of `iterate`, through `π` and `φ` nodes and `nothing` on some paths."""
function iterate_result(walk::Walk, @nospecialize(operand::Any))::Bool
    pending, seen = Any[operand], Set{Int}()
    while !isempty(pending)
        value = underlying(walk, pop!(pending))
        isnothing(value) && continue
        value isa Core.SSAValue || return false
        value.id in seen && continue
        push!(seen, value.id)
        statement = walk.ir.stmts[value.id][:stmt]
        if statement isa Core.PhiNode
            append!(pending, (statement.values[edge] for edge in eachindex(statement.values) if isassigned(statement.values, edge)))
        elseif !(statement isa Expr && statement.head === :call && call_parts(walk, statement)[1] === iterate)
            return false
        end
    end
    return true
end

"""
Certainty that call of `callee` on `operands` in `walk` starts operand at `position` through generic method: Base or
Core method that takes `Any` there. Other Base match keeps iteration contract; other match for multi-pass type makes
restart harmless: both keep `definite`. Operand that admits `Iterators.Stateful` reaches generic method with it, so
match that cannot take it keeps `definite` too. Other package match decides start for its values, though it takes
`Any` there (`map(::typeof(f), xs)`): `possible`. No generic match gives `nothing`: package method, as `minimum` of
distribution, decides start.
"""
function generic_start(walk::Walk, @nospecialize(callee::Any), operands::AbstractVector{Any}, position::Integer)::Union{Nothing, Confidence.T}
    matches = Base._methods_by_ftype(Tuple{Core.Typeof(callee), Any[operand_type(walk, operand) for operand in operands]...}, -1, walk.world)
    matches isa Vector || return Confidence.possible
    declared = Any[declared_argument(match.method.sig, position) for match in matches]
    base = Bool[Base.moduleroot(match.method.module) in (Base, Core) for match in matches]
    any(base[index] && declared[index] === Any for index in eachindex(matches)) || return nothing
    witness = Iterators.Stateful <: operand_type(walk, operands[position])
    harmless(type::Any)::Bool = type isa Type && type !== Union{} && (type <: MULTI_PASS || (witness && typeintersect(type, Iterators.Stateful) === Union{}))
    return all(base[index] || harmless(declared[index]) for index in eachindex(matches)) ? Confidence.definite : Confidence.possible
end

"""
Type method `signature` declares at argument `position`, `Vararg` element and type variable bound included; `nothing`
when method takes no such argument.
"""
function declared_argument(@nospecialize(signature::Type), position::Integer)::Any
    parameters = Base.unwrap_unionall(signature).parameters
    isempty(parameters) && return nothing
    parameter = position + 1 <= length(parameters) ? parameters[position + 1] : parameters[end]
    (position + 1 > length(parameters) && !Base.isvarargtype(parameter)) && return nothing
    parameter = Base.unwrapva(parameter)
    return Base.rewrap_unionall(parameter isa TypeVar ? parameter.ub : parameter, signature)
end

"""
Iterators package method starts twice or lets escape after start, in unit `walk` of `method` with `spans` of its IR
statements, and blind spots. Later event pairs with first earlier event of same object on one path; two escapes make
no pair. Pair with start that only specialized method serves is blind spot `SPECIALIZED_START`; pair with start of
`blind` kind (`pass_kind`) is blind spot `NESTED_PARAMETER`.
"""
function stateful_reuses(walk::Walk, method::Method, spans::AbstractVector{Span})::Tuple{Vector{StatefulReuse}, Vector{BlindSpot}}
    Base.require_one_based_indexing(spans)
    # Escaping value can hold iterator (returned tuple), so only start needs type of either kind.
    events = IteratorEvent[event for index in 1:length(walk.ir.stmts) for event in iterator_events(walk, index) if event.escapes || start_kind(walk, event.operand) in (Pass.open, Pass.blind)]
    found, spots, following = StatefulReuse[], BlindSpot[], Dict{Tuple{Int, Vector{Int}}, Set{Int}}()
    any(event -> !event.escapes, events) || return found, spots
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
        # Later direct start can still pair with other earlier event.
        cause = earlier.specialized || later.specialized ? SPECIALIZED_START : start_kind(walk, started.operand) === Pass.blind ? NESTED_PARAMETER : nothing
        if !isnothing(cause)
            push!(spots, BlindSpot(cause, spans[later.index]))
            continue
        end
        push!(found, StatefulReuse(spans[earlier.index], spans[later.index], earlier.escapes, later.escapes, earlier === later, value_text(walk, method, started.operand), confidence))
        break
    end
    return unique!(found), unique!(spots)
end

"""Whether events `one` and `other` are one statement and operand path of one starts with path of other."""
function nested(one::IteratorEvent, other::IteratorEvent)::Bool
    one.index == other.index || return false
    shorter = min(length(one.position), length(other.position))
    return length(one.position) != length(other.position) && @view(one.position[1:shorter]) == @view(other.position[1:shorter])
end

"""
Iterator events of statement `index` of `walk`: returned value escapes; call starts or lets operands escape. Code that
consumes `zip` result, or lets it escape to caller, starts each zipped operand (`joint_starts!`).
"""
function iterator_events(walk::Walk, index::Integer)::Vector{IteratorEvent}
    statement, found = walk.ir.stmts[index][:stmt], IteratorEvent[]
    if statement isa Core.ReturnNode
        isdefined(statement, :val) && push!(found, IteratorEvent(index, [1], statement.val, true, Confidence.definite, false))
    elseif statement isa Expr && statement.head === :call
        callee, operands = call_parts(walk, statement)
        isnothing(operands) && return found
        starts = started_positions(walk, callee, operands)
        # Consuming call of open operand: package methods beside generic one decide start for their types.
        protocol = callee === iterate || callee === Base.indexed_iterate
        for position in starts
            certainty = protocol || start_kind(walk, operands[position]) !== Pass.open ? Confidence.definite : generic_start(walk, callee, operands, position)
            push!(found, IteratorEvent(index, [position], operands[position], false, something(certainty, Confidence.definite), isnothing(certainty)))
        end
        if isempty(found) && callee === isempty && length(operands) == 1
            confidence = isempty_start(walk, operand_type(walk, operands[1]))
            isnothing(confidence) || push!(found, IteratorEvent(index, [1], operands[1], false, confidence, false))
        end
        append!(found, (IteratorEvent(index, [position], operands[position], true, Confidence.definite, false) for position in escaped_positions(walk, callee, operands)))
    end
    counts = Dict{Any, Int}()
    foreach(event -> joint_starts!(found, counts, walk, event), copy(found))
    return found
end

"""
Push onto `found` starts of operands that `zip` result of `event` in `walk` iterates, at its statement and below its path,
with its certainty. `counts` holds starts of each underlying operand: two show reuse, so nested `zip(z, z)` stays linear.
"""
function joint_starts!(found::AbstractVector{IteratorEvent}, counts::AbstractDict{Any, <:Integer}, walk::Walk, event::IteratorEvent)::Nothing
    parts = joint_operands(walk, event.operand)
    isnothing(parts) && return nothing
    for (inner, part) in enumerate(parts)
        key = underlying(walk, part)
        get(counts, key, 0) >= 2 && continue
        counts[key] = get(counts, key, 0) + 1
        start = IteratorEvent(event.index, Int[event.position; inner], part, false, event.confidence, event.specialized)
        push!(found, start)
        joint_starts!(found, counts, walk, start)
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

"""Source text of value `operand` of `walk` in `method`: its one caller place, else `nothing`."""
function value_text(walk::Walk, method::Method, @nospecialize(operand::Any))::Union{Nothing, String}
    value = operand_value(walk, operand)
    (value.fresh || length(value.places) != 1) && return nothing
    return place_text(method, only(value.places))
end
