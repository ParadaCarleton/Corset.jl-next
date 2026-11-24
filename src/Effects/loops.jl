# Loop writes of name tier (F48; `phase5.md`, row 7): writes to collection inside loop that iterates it.

using EnumX: @enumx

"""Blind spot cause of loop write through `Deep` place: name tier cannot tell objects below one root apart."""
const LOOP_UNKNOWN = "loop write place unknown"

"""
How write to place meets object at other place: `none`; `exact`: same place, or place below written one when write
covers places below; `unknown`: either is `Deep` of shared root.
"""
@enumx Overlap none exact unknown

"""
Writes to collection inside each loop of `walk`, with `spans` of its IR statements, and blind spots of writes through
unknown place. Loop step `iterate(x, state)` closes loop over `x`; loop starts at `iterate(x)` on same operand, or at
its step when none exists.
"""
function loop_writes(walk::Walk, spans::AbstractVector{Span})::Tuple{Vector{LoopWrite}, Vector{BlindSpot}}
    Base.require_one_based_indexing(spans)
    found, spots = LoopWrite[], BlindSpot[]
    steps = filter(index -> (operands = iterate_operands(walk, index); !isnothing(operands) && length(operands) == 2), 1:length(walk.ir.stmts))
    isempty(steps) && return (found, spots)
    domtree = CC.construct_domtree(walk.ir.cfg.blocks)
    for index in steps
        collection = something(iterate_operands(walk, index))[1]
        start = findfirst(other -> (started = iterate_operands(walk, other); !isnothing(started) && length(started) == 1 && started[1] === collection), 1:length(walk.ir.stmts))
        sources = origins(walk, collection)
        for statement in loop_statements(walk.ir, index, domtree)
            write = loop_write(walk, statement, collection, sources)
            isnothing(write) && continue
            callee, confidence = write
            if isnothing(confidence)
                push!(spots, BlindSpot(LOOP_UNKNOWN, spans[statement]))
            else
                push!(found, LoopWrite(spans[something(start, index)], spans[statement], callee, confidence))
            end
        end
    end
    return unique!(found), unique!(spots)
end

"""Operands of `iterate` call at statement `index` of `walk`; `nothing` for other statement."""
function iterate_operands(walk::Walk, index::Integer)::Union{Nothing, Vector{Any}}
    statement = walk.ir.stmts[index][:stmt]
    statement isa Expr || return nothing
    statement.head === :call || return nothing
    callee, operands = call_parts(walk, statement)
    return callee === iterate ? operands : nothing
end

"""
Statements of loop that step at statement `index` closes: natural loop of back edges that carry step result into `φ`
node of header. Back edge comes from block that header dominates, so step ahead of `while` and preheader of inner loop
close none. Body is header and blocks that reach back edge without header: code after inner loop stays outside it.
"""
function loop_statements(ir::CC.IRCode, index::Integer, domtree::CC.DomTree)::Vector{Int}
    blocks, found = ir.cfg.blocks, step_edges(ir, index)
    isnothing(found) && return Int[]
    header, edges = found
    latches = filter(edge -> CC.dominates(domtree, header, edge), edges)
    isempty(latches) && return Int[]
    body = push!(reached(latches, other -> other == header ? Int[] : blocks[other].preds), header)
    return Int[statement for other in sort!(collect(body)) for statement in blocks[other].stmts]
end

"""Block of `φ` node in `ir` that takes value of statement `index`, and predecessor blocks that carry it; `nothing` when none does."""
function step_edges(ir::CC.IRCode, index::Integer)::Union{Nothing, Tuple{Int, Vector{Int}}}
    step = Core.SSAValue(index)
    for other in 1:length(ir.stmts)
        node = ir.stmts[other][:stmt]
        node isa Core.PhiNode || continue
        edges = Int[node.edges[position] for position in eachindex(node.values) if isassigned(node.values, position) && node.values[position] === step]
        isempty(edges) || return (CC.block_for_inst(ir.cfg, other), edges)
    end
    return nothing
end

"""Blocks that `starts` reach along `next` edges, `starts` included. Entry block has predecessor 0: function entry."""
function reached(starts::AbstractVector{<:Integer}, next::F)::Set{Int} where {F <: Function}
    found, pending = Set{Int}(starts), append!(Int[], starts)
    while !isempty(pending)
        for other in next(pop!(pending))
            (other < 1 || other in found) && continue
            push!(found, other)
            push!(pending, other)
        end
    end
    return found
end

"""
Writing function name and confidence of write at statement `index` to loop `collection` with its `origins` (`sources`);
`nothing` confidence for write through unknown place (blind spot). `nothing` when statement writes no collection place,
replaces array element, or deletes from `DELETION_SAFE` collection.
"""
function loop_write(walk::Walk, index::Integer, @nospecialize(collection::Any), sources::Base.IdSet{Any})::Union{Nothing, Tuple{String, Union{Nothing, Confidence.T}}}
    statement = walk.ir.stmts[index][:stmt]
    statement isa Expr || return nothing
    statement.head === :call || return nothing
    callee, operands = call_parts(walk, statement)
    isnothing(operands) && return nothing
    store = callee in STORE_BUILTINS
    position = store ? 1 : bang_function(callee) ? written_position(walk, callee, operands) : nothing
    isnothing(position) && return nothing
    written = operands[position]
    same = any(origin -> origin in sources, origins(walk, written)) || same_place(walk, written, collection)
    # Size change and field store change their operand only; other `!` call can change objects below it.
    relation = same ? Overlap.exact : overlap(walk, written, collection, !store && !(callee in RESIZE_FUNCTIONS))
    relation == Overlap.none && return nothing
    type = operand_type(walk, written)
    callee === setindex! && type <: AbstractArray && return nothing
    callee in DELETE_FUNCTIONS && any(safe -> type <: safe, DELETION_SAFE) && return nothing
    relation == Overlap.unknown && return (string(nameof(callee)), nothing)
    return (string(nameof(callee)), (same && callee in RESIZE_FUNCTIONS) ? Confidence.definite : Confidence.possible)
end

"""
IR values `operand` can be same object as: itself, and operands of view calls and `π` nodes it comes from. Set holds
values by identity; each value costs one visit, so shared operands (`zip(z, z)`) stay linear.
"""
function origins(walk::Walk, @nospecialize(operand::Any))::Base.IdSet{Any}
    found, pending = Base.IdSet{Any}(), Any[operand]
    while !isempty(pending)
        current = pop!(pending)
        current in found && continue
        push!(found, current)
        current isa Core.SSAValue || continue
        statement = walk.ir.stmts[current.id][:stmt]
        statement isa Core.PiNode && (push!(pending, statement.val); continue)
        statement isa Expr || continue
        statement.head === :call || continue
        callee, operands = call_parts(walk, statement)
        (isnothing(operands) || !(callee in ALIAS_FUNCTIONS) || callee in ELEMENT_ALIASES) && continue
        append!(pending, (other for other in operands if !callable(walk, other)))
    end
    return found
end

"""
Whether IR operands `first` and `second` are each exactly one caller place, same for both, on no fresh path. Place
past `Element` step, `Deep` place, or global state no binding names can be other object at each load.
"""
function same_place(walk::Walk, @nospecialize(first::Any), @nospecialize(second::Any))::Bool
    one, other = operand_value(walk, first), operand_value(walk, second)
    (one.fresh || other.fresh || length(one.places) != 1 || one.places != other.places) && return false
    return object_place(only(one.places))
end

"""Whether `place` names one object: field and tuple steps below argument or global. Element place names every element."""
object_place(place::Place.Type)::Bool = @match place begin
    Place.At(Root.Elsewhere(), _) => false
    Place.At(_, steps) => !any(step -> step == Step.Element(), steps)
    Place.Deep(_) => false
end

"""Closest overlap of places of `written` operand with places of `collection` operand (`place_overlap`)."""
function overlap(walk::Walk, @nospecialize(written::Any), @nospecialize(collection::Any), below::Bool)::Overlap.T
    found, places = Overlap.none, operand_value(walk, collection).places
    for target in operand_value(walk, written).places, place in places
        relation = place_overlap(target, place, below)
        relation == Overlap.exact && return relation
        relation == Overlap.unknown && (found = relation)
    end
    return found
end

"""
Overlap of write to `target` with object at `place`, write covering places below when `below`. Global state that no
binding names overlaps none.
"""
function place_overlap(target::Place.Type, place::Place.Type, below::Bool)::Overlap.T
    (place_root(target) == place_root(place) && place_root(place) != Root.Elsewhere()) || return Overlap.none
    return @match (target, place) begin
        (Place.At(_, steps), Place.At(_, others)) => (steps == others || (below && length(steps) < length(others) && steps == @view(others[1:length(steps)]))) ? Overlap.exact : Overlap.none
        _ => Overlap.unknown
    end
end
