# Array events of unit for `lifecycle` stage (`lifecycle.md`): allocations, events of their uses, paths, fill loops.

using ..StandIns: ArrayStandIn, DenseStandIn

"""Base functions whose result is filled array (`lifecycle.md`, Allocations)."""
const FILLED = Base.IdSet{Any}(Any[zeros, ones, fill, trues, falses])

"""Base functions whose result is new array of elements they compute or iterate."""
const COLLECTING = Base.IdSet{Any}(Any[collect, map])

"""Base functions whose result is new array that copies operands."""
const COPYING = Base.IdSet{Any}(Any[copy, vcat, hcat])

"""Base arithmetic with two or more operands: result is new value. One operand can give it back (`*(A)`, `+(view)`)."""
const ARRAY_ARITHMETIC = Base.IdSet{Any}(Any[+, -, *, /, (\)])

"""Base reductions: result combines elements, never collection operand itself (`sum(a; dims)` builds new array)."""
const REDUCTIONS = Base.IdSet{Any}(Any[sum, prod, maximum, minimum, extrema, any, all, count, reduce, foldl, foldr, mapreduce])

"""Functions that read shape of array operand, never its elements (`lifecycle.md`, Events)."""
const SHAPE_FUNCTIONS = Base.IdSet{Any}(
    Any[size, length, axes, eachindex, firstindex, lastindex, ndims, eltype, isempty, similar, keys, LinearIndices, CartesianIndices, checkbounds, isassigned, sizeof, strides, stride, ===, isa, typeof, isdefined],
)

"""`!` functions that write every element of written operand. `copyto!` counts with two operands only."""
const WHOLE_WRITES = Base.IdSet{Any}(Any[fill!, copyto!, map!, broadcast!, Base.materialize!, Random.rand!, Random.randn!])

"""`WHOLE_WRITES` that write as many elements as their shortest source has: whole only when each source has same extent."""
const PREFIX_WRITES = Base.IdSet{Any}(Any[copyto!, map!])

"""`!` functions that read elements of source operands; other `!` functions store source operand itself (`fill!(a, a)`)."""
const READING_WRITES = Base.IdSet{Any}(Any[copyto!, map!, broadcast!, Base.materialize!, append!, prepend!])

"""`!` functions that read old elements of array they write (`sort!(a)`): unset element throws or gives garbage."""
const CONSUMING_WRITES = Base.IdSet{Any}(Any[sort!, reverse!, permute!, invpermute!, unique!, filter!, replace!, keepat!])

"""Functions whose iteration covers every index of each array operand (fill loop)."""
const INDEX_RANGES = Base.IdSet{Any}(Any[eachindex, LinearIndices, CartesianIndices])

"""
Control flow of unit IR for event paths: blocks that reach normal return (`returning`), post-dominators of each such
block over returning blocks, and headers of loops that hold each block.
"""
struct Flow
    returning::BitSet
    postdominators::Vector{BitSet}
    loops::Vector{BitSet}
end

"""Whether `type` is array type that allocation gives: `Array`, `BitArray` or array stand-in."""
allocated_type(@nospecialize(type::Any))::Bool = type isa Type && type !== Union{} && type <: Union{Array, BitArray, ArrayStandIn, DenseStandIn}

"""Whether call `operands` index array with range, array or `Colon` operand: copy of part (`A[:, i]`)."""
function slice(walk::Walk, operands::AbstractVector{Any})::Bool
    Base.require_one_based_indexing(operands)
    (length(operands) >= 2 && operand_type(walk, operands[1]) <: AbstractArray) || return false
    return any(operand -> operand_type(walk, operand) <: Union{AbstractArray, Colon}, @view(operands[2:end]))
end

"""Allocation kind of call `callee` with `operands`; `nothing` when call allocates no array by Base table."""
function call_allocation(walk::Walk, @nospecialize(callee::Any), operands::AbstractVector{Any})::Union{Nothing, AllocationKind.T}
    Base.require_one_based_indexing(operands)
    callee === similar && return AllocationKind.undef
    callee isa Type && callee <: Union{Array, BitArray} && any(operand -> operand_type(walk, operand) <: UndefInitializer, operands) && return AllocationKind.undef
    callee in FILLED && return AllocationKind.filled
    callee === Base.materialize && length(operands) == 1 && operand_type(walk, operands[1]) <: Broadcast.Broadcasted && return AllocationKind.broadcast
    callee in COLLECTING && return AllocationKind.collected
    callee === getindex && slice(walk, operands) && return AllocationKind.slice
    callee in COPYING && return AllocationKind.copied
    return nothing
end

"""Allocation kind of statement `index` of `walk`, its callee and operands; `nothing` when statement allocates no array."""
function allocation(walk::Walk, index::Integer)::Union{Nothing, Tuple{AllocationKind.T, Any, Vector{Any}}}
    statement = walk.ir.stmts[index][:stmt]
    (statement isa Expr && statement.head === :call) || return nothing
    allocated_type(CC.widenconst(walk.ir.stmts[index][:type])) || return nothing
    callee, operands = call_parts(walk, statement)
    isnothing(operands) && return nothing
    kind = call_allocation(walk, callee, operands)
    return isnothing(kind) ? nothing : (something(kind), callee, operands)
end

"""
Size operands of `undef` or `filled` allocation call `callee` with `operands`: operands after array, value, `undef`
and element type operands. `nothing` for other kind, or `similar` that copies size of its array.
"""
function size_operands(walk::Walk, kind::AllocationKind.T, @nospecialize(callee::Any), operands::AbstractVector{Any})::Union{Nothing, Vector{Any}}
    kind in (AllocationKind.undef, AllocationKind.filled) || return nothing
    Base.require_one_based_indexing(operands)
    skipped = callee === similar || callee === fill ? 1 : 0
    found = Any[operand for operand in @view(operands[(skipped + 1):end]) if !(operand_type(walk, operand) <: Union{Type, UndefInitializer})]
    return callee === similar && isempty(found) ? nothing : found
end

"""Constant dimensions that size `operands` give: integers or one tuple of them; `nothing` when one is not constant."""
function constant_dimensions(walk::Walk, operands::AbstractVector{Any})::Union{Nothing, Vector{Int}}
    found = Int[]
    for operand in operands
        constant = constant_value(walk, operand)
        if constant isa Int
            push!(found, constant)
        elseif constant isa Tuple{Vararg{Int}}
            append!(found, constant)
        else
            return nothing
        end
    end
    return found
end

"""Control flow of `ir` (`Flow`)."""
function unit_flow(ir::CC.IRCode)::Flow
    blocks = ir.cfg.blocks
    total = length(blocks)
    exits = [block for block in 1:total if (final = ir.stmts[blocks[block].stmts[end]][:stmt]; final isa Core.ReturnNode && isdefined(final, :val))]
    returning = BitSet(reached(exits, block -> blocks[block].preds))
    postdominators = [block in exits ? BitSet(block) : copy(returning) for block in 1:total]
    changed = true
    while changed
        changed = false
        for block in reverse(1:total)
            (block in returning && !(block in exits)) || continue
            found = reduce(intersect, (postdominators[next] for next in blocks[block].succs if next in returning); init = copy(returning))
            push!(found, block)
            found == postdominators[block] || (postdominators[block] = found; changed = true)
        end
    end
    domtree = CC.construct_domtree(blocks)
    loops = [BitSet() for _ in 1:total]
    for latch in 1:total, header in blocks[latch].succs
        CC.dominates(domtree, header, latch) || continue
        foreach(block -> push!(loops[block], header), push!(reached([latch], block -> block == header ? Int[] : blocks[block].preds), header))
    end
    return Flow(returning, postdominators, loops)
end

"""Path of event in `event` block from allocation in `allocation` block (`lifecycle.md`, Paths)."""
function event_path(flow::Flow, allocation::Integer, event::Integer)::ArrayPath.T
    issubset(flow.loops[event], flow.loops[allocation]) || return ArrayPath.loop
    sure = flow.loops[event] == flow.loops[allocation] && allocation in flow.returning && event in flow.postdominators[allocation]
    return sure ? ArrayPath.sure : ArrayPath.branch
end

"""Name of Base function `callee`; `nothing` for other callee."""
base_name(@nospecialize(callee::Any))::Union{Nothing, Symbol} = callee isa Function && library_owner(callee) === :Base ? nameof(callee) : nothing

"""Coverage and constant indices of element access with index `operands`."""
function element_coverage(walk::Walk, operands::AbstractVector{Any})::Tuple{Coverage.T, Vector{Int}}
    indices = Any[constant_value(walk, operand) for operand in operands]
    all(index -> index isa Int, indices) || return (Coverage.unknown, Int[])
    return (Coverage.element, Int[index for index in indices])
end

"""Base collections whose fields hold storage of their elements alone; other collection can hold more (view holds parent)."""
const STORAGE = Union{Array, BitArray, GenericMemory, Dict, IdDict, Set, Base.IdSet}

"""
Whether value of type `holder` can hold object of type `held` inside: element or field type that meets `held`, at
most `depth` steps deep. Union holds what a member holds; abstract or other holder can hold anything.
"""
function can_hold(@nospecialize(holder::Any), @nospecialize(held::Any), depth::Integer)::Bool
    depth == 0 && return true
    holder isa Union && return can_hold(holder.a, held, depth) || can_hold(holder.b, held, depth)
    holder isa DataType || return holder !== Union{}
    # `Type{T}` is abstract but holds no array, so this check comes first.
    (isbitstype(holder) || holder <: Union{AbstractString, Symbol, Module, Type}) && return false
    Base.isabstracttype(holder) && return true
    elements = holder <: Union{AbstractArray, AbstractDict, AbstractSet} ? Any[element_type(holder)] : Any[]
    inner = if holder <: STORAGE
        elements
    elseif holder <: Tuple
        # Open-length tuple (`Tuple{Vararg{T}}`) has no field count; its element type stands for every field.
        Any[Base.unwrapva(parameter) for parameter in holder.parameters]
    else
        # View or wrapper holds its parent in field (`SubArray`).
        Any[elements; Any[fieldtype(holder, index) for index in 1:fieldcount(holder)]]
    end
    return any(type -> typeintersect(type, held) !== Union{} || can_hold(type, held, depth - 1), inner)
end

"""Most steps `can_hold` looks into holder."""
const HOLD_DEPTH = 3

"""Kind, coverage and indices of one event."""
const EventShape = Tuple{ArrayEventKind.T, Coverage.T, Vector{Int}}

"""Events that one statement gives, in order."""
const Classified = Vector{EventShape}

"""
What proves size of allocation `value`: `source` whose axes it copies, and its one `size` operand (`nothing`: none).
`written` holds roots that `!` calls of unit write: such source can change size after allocation (`pop!(x)`).
"""
struct Extent
    value::Core.SSAValue
    source::Any
    size::Any
    written::Base.IdSet{Any}
end

"""
Events of call `callee` with `operands` at statement `index` on array at operand `positions`, or `:same` when result
is same array, `:derived` when result is view or wrapper of it, `:lazy` when result is broadcast that reads it whole
later (`lifecycle.md`, Events). `extent` proves size of allocation (`same_extent`).
"""
function call_event(walk::Walk, index::Integer, @nospecialize(callee::Any), operands::AbstractVector{Any}, positions::AbstractVector{<:Integer}, extent::Extent)::Union{Symbol, Classified}
    Base.require_one_based_indexing(operands)
    held = operand_type(walk, operands[first(positions)])
    (callee === identity || (callee === typeassert && positions == [1])) && return :same
    callee in SHAPE_FUNCTIONS && return [(ArrayEventKind.shape, Coverage.unknown, Int[])]
    callee === getindex && positions == [1] && return [(ArrayEventKind.read, element_coverage(walk, @view(operands[2:end]))...)]
    # View holds its index operand: `values[indices] .= 0` writes `values` only. Bounds check reads it unless `@inbounds`;
    # Boolean mask is counted even then.
    if callee in INDEX_VIEWS && positions != [1]
        checked = iszero(walk.ir.stmts[index][:flag] & CC.IR_FLAG_INBOUNDS) || held <: AbstractArray{Bool}
        return [(checked ? EventShape[(ArrayEventKind.read, Coverage.whole, Int[])] : EventShape[]); (ArrayEventKind.escape, Coverage.unknown, Int[])]
    end
    # Target of `a[i] .= x`: element for scalar index, else view; view of every element is array itself.
    if callee in DOT_VIEWS && positions == [1]
        view_call(walk, callee, operands) || return [(ArrayEventKind.read, element_coverage(walk, @view(operands[2:end]))...)]
        return whole_view(walk, operands, extent) ? :same : :derived
    end
    callee === setindex! && positions == [1] && return [(ArrayEventKind.write, element_coverage(walk, @view(operands[3:end]))...)]
    callee in (first, last, only) && return [(ArrayEventKind.read, Coverage.unknown, Int[])]
    # `String(v)` takes memory of byte vector `v`, as pointer conversion exposes it.
    callee in (pointer, Base.cconvert, Base.unsafe_convert, String) && return [(ArrayEventKind.escape, Coverage.unknown, Int[])]
    # Broadcast reads every element of its operands when it runs.
    callee === Base.broadcasted && return :lazy
    callee in ALIAS_FUNCTIONS && return :derived
    callee in STORE_BUILTINS && return [(positions == [1] ? ArrayEventKind.write : ArrayEventKind.escape, Coverage.unknown, Int[])]
    if bang_function(callee)
        written = written_position(walk, callee, operands)
        if !isnothing(written) && written in positions
            # Array as source too: `map!(f, a, a)` reads it before it writes; `fill!(a, a)` stores it.
            reading = callee in READING_WRITES
            sources = @view(operands[(something(written) + 1):end])
            # `sort!(a)`, and `map!(f, a)` without other source, read old elements of `a`.
            consuming = callee in CONSUMING_WRITES || (callee === map! && isempty(sources))
            reads = consuming || (length(positions) > 1 && reading) ? EventShape[(ArrayEventKind.read, Coverage.whole, Int[])] : EventShape[]
            stores = length(positions) > 1 && !reading ? EventShape[(ArrayEventKind.escape, Coverage.unknown, Int[])] : EventShape[]
            callee in RESIZE_FUNCTIONS && return [reads; (ArrayEventKind.resize, Coverage.unknown, Int[]); stores]
            whole = callee in WHOLE_WRITES && (callee !== copyto! || length(operands) == 2) &&
                (!(callee in PREFIX_WRITES) || all(operand -> same_extent(walk, operand, extent), sources))
            return [reads; (ArrayEventKind.write, whole ? Coverage.whole : Coverage.unknown, Int[]); stores]
        end
        # Name promises write of one operand: package call can write others too (`colwise!(metric, r, a, b)`).
        isnothing(library_owner(callee)) && return [(ArrayEventKind.escape, Coverage.unknown, Int[])]
        # Library call writes subject after functors instead of functor (`map!(scale, r, x)`).
        !isnothing(written) && any(in(positions), functor_followers(walk, operands, something(written))) && return [(ArrayEventKind.escape, Coverage.unknown, Int[])]
        # Other operand of `!` call goes into written operand when its type can hold array (`push!(c, a)`).
        return passed(!isnothing(written) && can_hold(operand_type(walk, operands[something(written)]), held, HOLD_DEPTH))
    end
    if builds_new(callee, length(operands))
        # Copy keeps unset slots of reference elements unread: `copy(Vector{String}(undef, 2))` throws no `UndefRefError`.
        references = !(held isa DataType && Base.allocatedinline(element_type(held)))
        reads = reads_slots(callee, Any[operand_type(walk, operand) for operand in operands], held)
        slot_copy(callee) && references && !reads && return [(ArrayEventKind.escape, Coverage.unknown, Int[])]
        return passed(false)
    end
    # Other result can be operand itself (`float(a)`, package `pass(a) = a`) or hold it.
    result = CC.widenconst(walk.ir.stmts[index][:type])
    return passed(typeintersect(result, held) !== Union{} || can_hold(result, held, HOLD_DEPTH))
end

"""
Whether call of `callee` with `count` operands builds new value from elements of its array operand, never from
operand itself: Base copy, collect and reduction, arithmetic with two or more operands, `Array` constructor. Wrapper
result type (`vcat` of stand-in) holds no operand then.
"""
builds_new(@nospecialize(callee::Any), count::Integer)::Bool =
    slot_copy(callee) || callee in COLLECTING || callee in REDUCTIONS || (callee in ARRAY_ARITHMETIC && count >= 2)

"""Whether `callee` can copy slots of array operand as they are: `copy`, `vcat`, `hcat`, `Array` and `BitArray` constructors."""
slot_copy(@nospecialize(callee::Any))::Bool = callee in COPYING || (callee isa Type && callee <: Union{Array, BitArray})

"""
Whether concatenation `callee` of operands of `types` reads slots of `Array` operand of type `held`. Julia 1.13 throws
`UndefRefError` on unset slot for `vcat` with operand of two or more dimensions, `hcat` of vectors only or with operand
of three or more dimensions, and operands of other element types. Unknown dimensions or array type: no read.
"""
function reads_slots(@nospecialize(callee::Any), types::AbstractVector, @nospecialize(held::Any))::Bool
    (callee in (vcat, hcat) && held isa DataType && held <: Array) || return false
    counts = Int[]
    for type in types
        type <: AbstractArray || continue
        count = dimension_count(type)
        (type isa DataType && type <: Array && !isnothing(count)) || return false
        eltype(type) == eltype(held) || return true
        push!(counts, something(count))
    end
    return callee === vcat ? maximum(counts) >= 2 : maximum(counts) >= 3 || all(==(1), counts)
end

"""Whether index `operands` of `dotview` call cover every element of allocation of `extent`: all `Colon`, or one covering range."""
function whole_view(walk::Walk, operands::AbstractVector{Any}, extent::Extent)::Bool
    Base.require_one_based_indexing(operands)
    indices = @view(operands[2:end])
    all(index -> operand_type(walk, index) <: Colon, indices) && return true
    return length(indices) == 1 && covering_range(walk, only(indices), extent)
end

"""Event of array that call takes as operand: `escape` when call can keep it, else whole `read`."""
passed(kept::Bool)::Classified = [kept ? (ArrayEventKind.escape, Coverage.unknown, Int[]) : (ArrayEventKind.read, Coverage.whole, Int[])]

"""
Whether `operand` has as many elements as allocation of `extent`: same array, its source, or array whose `length` is
its one size operand.
"""
function same_extent(walk::Walk, @nospecialize(operand::Any), extent::Extent)::Bool
    root = underlying(walk, operand)
    root === underlying(walk, extent.value) && return true
    root in extent.written && return false
    !isnothing(extent.source) && root === underlying(walk, extent.source) && return true
    counted = isnothing(extent.size) ? nothing : call_of(walk, extent.size)
    isnothing(counted) && return false
    counter, counted_operands = something(counted)
    return counter === length && length(counted_operands) == 1 && underlying(walk, only(counted_operands)) === root
end

"""Roots of values that `!` calls of `walk` take as written operand."""
function written_roots(walk::Walk)::Base.IdSet{Any}
    roots = Base.IdSet{Any}()
    for index in 1:length(walk.ir.stmts)
        call = call_of(walk, Core.SSAValue(index))
        isnothing(call) && continue
        callee, operands = something(call)
        bang_function(callee) || continue
        position = written_position(walk, callee, operands)
        isnothing(position) || push!(roots, underlying(walk, operands[something(position)]))
    end
    return roots
end

"""
Events of statement `index` of `walk` that uses array `current`: as for `call_event`; `joined` at `φ` node, `escape`
at return, `new`, foreign call or splatted call. `extent` proves size of allocation (`same_extent`).
"""
function statement_event(walk::Walk, index::Integer, current::Core.SSAValue, extent::Extent)::Union{Symbol, Classified}
    statement = walk.ir.stmts[index][:stmt]
    statement isa Core.PiNode && return :same
    statement isa Union{Core.PhiNode, Core.PhiCNode, Core.UpsilonNode} && return [(ArrayEventKind.joined, Coverage.unknown, Int[])]
    statement isa Expr && statement.head === :call || return [(ArrayEventKind.escape, Coverage.unknown, Int[])]
    callee, operands = call_parts(walk, statement)
    positions = isnothing(operands) ? Int[] : Int[position for (position, operand) in enumerate(operands) if operand === current]
    # Splat hides positions; use as callee passes array on.
    isempty(positions) && return [(ArrayEventKind.escape, Coverage.unknown, Int[])]
    return call_event(walk, index, callee, operands, positions, extent)
end

"""
Range operand of loop whose iteration covers every element of allocation of `extent` (fill loop): index function of
array (`eachindex`, `LinearIndices`, `CartesianIndices`) or of source that it copies axes of, `axes(a, 1)` of vector,
`1:length(a)` or `1:lastindex(a)` of `Array`, or `1:n` with `n` its one size operand.
"""
function covering_range(walk::Walk, @nospecialize(range::Any), extent::Extent)::Bool
    call = call_of(walk, range)
    isnothing(call) && return false
    callee, operands = something(call)
    value, source = extent.value, extent.source
    # Source that `!` call writes can shrink after allocation (`pop!(x)`).
    covered(root::Any)::Bool = root === underlying(walk, value) || (!(root in extent.written) && !isnothing(source) && root === underlying(walk, source))
    covers(operand::Any)::Bool = covered(underlying(walk, operand))
    callee in INDEX_RANGES && return any(covers, operands)
    callee === axes && length(operands) == 2 && constant_value(walk, operands[2]) === 1 && covers(operands[1]) && return dimension_count(operand_type(walk, value)) == 1
    ranged = (callee === Colon() && length(operands) == 2 && constant_value(walk, operands[1]) === 1) || (callee === Base.OneTo && length(operands) == 1)
    ranged || return false
    stop = last(operands)
    !isnothing(extent.size) && underlying(walk, stop) === underlying(walk, extent.size) && return true
    counted = call_of(walk, stop)
    isnothing(counted) && return false
    counter, counted_operands = something(counted)
    return counter in (length, lastindex) && operand_type(walk, value) <: Union{Array, BitArray} && any(covers, counted_operands)
end

"""
Fill loops of array in `walk` that `same` values hold (`lifecycle.md`, Paths): for each, `setindex!` statement it covers, loop step
statement, and start statement before loop. `extent` proves size of allocation (`covering_range`).
"""
function fill_loops(walk::Walk, flow::Flow, users::AbstractVector{<:AbstractVector{<:Integer}}, same::AbstractVector{Core.SSAValue}, extent::Extent)::Vector{Tuple{Int, Int, Int}}
    ir, found = walk.ir, Tuple{Int, Int, Int}[]
    domtree = CC.construct_domtree(ir.cfg.blocks)
    for current in same, write in users[current.id]
        statement = ir.stmts[write][:stmt]
        statement isa Expr || continue
        statement.head === :call || continue
        callee, operands = call_parts(walk, statement)
        isnothing(operands) && continue
        (callee === setindex! && length(operands) == 3 && operands[1] === current) || continue
        index = underlying(walk, operands[3])
        loaded = call_of(walk, index)
        (isnothing(loaded) || something(loaded)[1] !== getfield || constant_value(walk, something(loaded)[2][2]) !== 1) && continue
        phi = underlying(walk, something(loaded)[2][1])
        phi isa Core.SSAValue || continue
        ir.stmts[phi.id][:stmt] isa Core.PhiNode || continue
        steps = fill_steps(walk, flow, domtree, phi, write, extent)
        isnothing(steps) || push!(found, (write, something(steps)...))
    end
    return found
end

"""
Step and start statements of loop whose header `φ` node `phi` iterates covering range, when `setindex!` statement
`write` runs on every iteration and loop exits only at its step; `nothing` else.
"""
function fill_steps(walk::Walk, flow::Flow, domtree::CC.DomTree, phi::Core.SSAValue, write::Integer, extent::Extent)::Union{Nothing, Tuple{Int, Int}}
    ir = walk.ir
    node = ir.stmts[phi.id][:stmt]::Core.PhiNode
    header = CC.block_for_inst(ir.cfg, phi.id)
    length(node.values) == 2 && all(position -> isassigned(node.values, position), 1:2) || return nothing
    inside = [header in flow.loops[edge] for edge in node.edges]
    count(inside) == 1 || return nothing
    start, step = node.values[findfirst(!, inside)], node.values[findfirst(inside)]
    start isa Core.SSAValue || return nothing
    step isa Core.SSAValue || return nothing
    started, stepped = call_of(walk, start), call_of(walk, step)
    (isnothing(started) || isnothing(stepped)) && return nothing
    (something(started)[1] === iterate && something(stepped)[1] === iterate && length(something(started)[2]) == 1) || return nothing
    range = something(started)[2][1]
    (something(stepped)[2][1] === range && covering_range(walk, range, extent)) || return nothing
    step_block = CC.block_for_inst(ir.cfg, step.id)
    CC.dominates(domtree, CC.block_for_inst(ir.cfg, write), step_block) || return nothing
    # Loop exit other than step skips writes of later iterations: `break`. Return and throw leave method.
    for block in 1:length(ir.cfg.blocks)
        header in flow.loops[block] && block != step_block || continue
        any(next -> !(header in flow.loops[next]), ir.cfg.blocks[block].succs) && return nothing
    end
    return (step.id, start.id)
end

"""Whether every array or tuple operand of broadcast that statement `index` materializes is `value`: result keeps its axes."""
function same_axes(walk::Walk, index::Integer, value::Core.SSAValue)::Bool
    pending, seen = Any[only(something(call_of(walk, Core.SSAValue(index)))[2])], Set{Any}()
    while !isempty(pending)
        operand = pop!(pending)
        # Broadcast can reuse one inner broadcast many times: visit each once.
        operand in seen && continue
        push!(seen, operand)
        call = call_of(walk, operand)
        if !isnothing(call) && something(call)[1] === Base.broadcasted
            # First operand is function that broadcast applies.
            append!(pending, something(call)[2][2:end])
        elseif operand_type(walk, operand) <: Union{AbstractArray, Tuple}
            underlying(walk, operand) === value || return false
        end
    end
    return true
end

"""Statements of `broadcasted` calls that build broadcast which statement `index` materializes."""
function broadcast_tree(walk::Walk, index::Integer)::Set{Int}
    found, pending = Set{Int}(), Any[only(something(call_of(walk, Core.SSAValue(index)))[2])]
    while !isempty(pending)
        operand = underlying(walk, pop!(pending))
        call = call_of(walk, operand)
        (isnothing(call) || something(call)[1] !== Base.broadcasted) && continue
        # Broadcast can reuse one inner broadcast many times: visit each once.
        operand.id in found && continue
        push!(found, operand.id)
        # First operand is function that broadcast applies.
        append!(pending, something(call)[2][2:end])
    end
    return found
end

"""Whether earlier allocation at statement `earlier` and broadcast at `index` have one concrete type: `.=` keeps it."""
function same_type(walk::Walk, earlier::Integer, index::Integer)::Bool
    type = CC.widenconst(walk.ir.stmts[index][:type])
    return isconcretetype(type) && CC.widenconst(walk.ir.stmts[earlier][:type]) == type
end

"""
Whether `allowed(user, found)` holds for each use of statement `value` through `π`, `identity` and `typeassert`: `found`
is what `statement_event` gives for `user`.
"""
function uses_pass(allowed::F, walk::Walk, users::AbstractVector{<:AbstractVector{<:Integer}}, written::Base.IdSet{Any}, value::Integer)::Bool where {F <: Function}
    pending, seen = [Core.SSAValue(value)], Set{Int}(value)
    while !isempty(pending)
        current = pop!(pending)
        for user in users[current.id]
            found = statement_event(walk, user, current, Extent(current, nothing, nothing, written))
            if found === :same
                user in seen || (push!(seen, user); push!(pending, Core.SSAValue(user)))
            elseif !allowed(user, found)
                return false
            end
        end
    end
    return true
end

"""
Whether loop alone sees arrays of rebind pair at loop header `phi` (`lifecycle.md`, Rebind): `earlier` allocation runs
once per loop entry, and loop reaches no use of it but joins; `φ` value has no use after broadcast at `index` in
iteration; no array escapes but by return. Then `.=` keeps behavior.
"""
function exclusive(walk::Walk, flow::Flow, users::AbstractVector{<:AbstractVector{<:Integer}}, written::Base.IdSet{Any}, earlier::Integer, index::Integer, phi::Integer)::Bool
    ir = walk.ir
    block_of(statement::Integer)::Int = CC.block_for_inst(ir.cfg, statement)
    header, start, body = block_of(phi), block_of(earlier), block_of(index)
    # Loop around header that leaves out earlier allocation enters header loop again with same array.
    all(loop -> loop == header || loop in flow.loops[start], flow.loops[header]) || return false
    # Blocks that run after loop entry, before earlier allocation runs again.
    after = delete!(reached([header], block -> block == start ? Int[] : ir.cfg.blocks[block].succs), start)
    inside(statement::Integer)::Bool = header in flow.loops[block_of(statement)]
    joins(statement::Integer)::Bool = ir.stmts[statement][:stmt] isa Core.PhiNode
    domtree, tree = CC.construct_domtree(ir.cfg.blocks), broadcast_tree(walk, index)
    before(user::Integer)::Bool = block_of(user) == body ? user < index : CC.dominates(domtree, block_of(user), body)
    # Kept: view (`:derived`), escape but return, or join into `φC` node.
    function kept(user::Integer, found::Union{Symbol, Classified})::Bool
        found isa Symbol && return found === :derived
        returned = ir.stmts[user][:stmt] isa Core.ReturnNode
        return any(((kind, _, _),) -> kind == ArrayEventKind.joined || (kind == ArrayEventKind.escape && !returned), found)
    end
    # Loop exit `φ` that joins only arrays of pair holds last contents either way.
    function exit_join(user::Integer)::Bool
        inside(user) && return false
        node = ir.stmts[user][:stmt]::Core.PhiNode
        for position in eachindex(node.values)
            isassigned(node.values, position) || return false
            value = underlying(walk, node.values[position])
            (value isa Core.SSAValue && value.id in (earlier, index, phi)) || return false
        end
        return true
    end
    earlier_passes = uses_pass(walk, users, written, earlier) do user, found
        joins(user) && return (user == phi || exit_join(user))
        # Loop sees contents that in-place broadcast writes; lazy broadcast before loop can run in it.
        return !(block_of(user) in after) && found !== :lazy && !kept(user, found)
    end
    # Exit after broadcast leaves `φ` value as old array, which in-place broadcast overwrote.
    later = delete!(reached([body], block -> block == header ? Int[] : ir.cfg.blocks[block].succs), header)
    stale = any(block -> any(next -> !(header in flow.loops[next]), ir.cfg.blocks[block].succs), later)
    phi_passes = uses_pass(walk, users, written, phi) do user, found
        user in tree && return true
        inside(user) || return !stale
        return !joins(user) && before(user) && !kept(user, found)
    end
    later_passes = uses_pass(walk, users, written, index) do user, found
        (user == phi || !inside(user)) && return true
        return !joins(user) && !kept(user, found)
    end
    return earlier_passes && phi_passes && later_passes
end

"""
Rebind pair of broadcast allocation at statement `index` in `block` (F41): loop header `φ` node that joins it with
array allocated before loop. `written` holds roots that `!` calls write (`written_roots`).
"""
function rebind_pair(walk::Walk, flow::Flow, users::AbstractVector{<:AbstractVector{<:Integer}}, spans::AbstractVector{Span}, written::Base.IdSet{Any}, index::Integer, block::Integer)::Union{Nothing, Rebind}
    ir = walk.ir
    for user in users[index]
        node = ir.stmts[user][:stmt]
        node isa Core.PhiNode || continue
        header = CC.block_for_inst(ir.cfg, user)
        (header in flow.loops[block] && length(node.values) == 2 && all(position -> isassigned(node.values, position), 1:2)) || continue
        outside = [!(header in flow.loops[edge]) for edge in node.edges]
        count(outside) == 1 || continue
        earlier = underlying(walk, node.values[findfirst(outside)])
        earlier isa Core.SSAValue || continue
        isnothing(allocation(walk, earlier.id)) && continue
        header in flow.loops[CC.block_for_inst(ir.cfg, earlier.id)] && continue
        return Rebind(spans[earlier.id], same_axes(walk, index, Core.SSAValue(user)), same_type(walk, earlier.id, index), exclusive(walk, flow, users, written, earlier.id, index, user))
    end
    return nothing
end

"""
Call at statement `index` of `walk` that uses `current`: Base function it calls, first position of `current` among its
positional operands, and Base function it takes as first operand (`vcat` in `reduce(vcat, a)`). `nothing` for each part
that statement lacks: other statement or callee, splat, operand that is no Base function.
"""
function statement_call(walk::Walk, index::Integer, current::Core.SSAValue)::Tuple{Union{Nothing, Symbol}, Union{Nothing, Int}, Union{Nothing, Symbol}}
    statement = walk.ir.stmts[index][:stmt]
    (statement isa Expr && statement.head === :call) || return (nothing, nothing, nothing)
    callee, operands = call_parts(walk, statement)
    isnothing(operands) && return (base_name(callee), nothing, nothing)
    found = something(operands)
    operator = isempty(found) ? nothing : base_name(constant_value(walk, first(found)))
    return (base_name(callee), findfirst(operand -> operand === current, found), operator)
end

"""
Array that statement `index` of `walk` allocates with `kind` by call `callee` with `operands`: events of uses of its
value, of `π` nodes, `identity` and `typeassert` of it, and of views and wrappers of it (`view`); fill loop replaces
its `setindex!` event with whole write. `lines` and `spans` give source statement and span of each IR statement;
`written` holds roots that `!` calls write (`written_roots`).
"""
function array_life(walk::Walk, flow::Flow, users::AbstractVector{<:AbstractVector{<:Integer}}, lines::AbstractVector{<:Integer}, spans::AbstractVector{Span}, written::Base.IdSet{Any}, index::Integer, kind::AllocationKind.T, @nospecialize(callee::Any), operands::AbstractVector{Any})::ArrayLife
    ir, value = walk.ir, Core.SSAValue(index)
    block = CC.block_for_inst(ir.cfg, index)
    path_of(statement::Integer)::ArrayPath.T = event_path(flow, block, CC.block_for_inst(ir.cfg, statement))
    sizes = size_operands(walk, kind, callee, operands)
    source = callee === similar && isnothing(sizes) ? operands[1] : nothing
    extent = Extent(value, source, !isnothing(sizes) && length(something(sizes)) == 1 ? only(something(sizes)) : nothing, written)
    # Each pending value: whether events through it act through view, and whether it is array itself.
    events, same, pending, seen = Tuple{Int, ArrayEvent}[], Core.SSAValue[], [(value, false, true)], Set{Int}(index)
    while !isempty(pending)
        current, view, itself = pop!(pending)
        itself && push!(same, current)
        for user in users[current.id]
            found = statement_event(walk, user, current, extent)
            if found isa Symbol
                user in seen && continue
                push!(seen, user)
                push!(pending, (Core.SSAValue(user), view || found === :derived, itself && found === :same))
                continue
            end
            for (event, coverage, indices) in found
                push!(events, (user, ArrayEvent(spans[user], event, coverage, indices, path_of(user), statement_call(walk, user, current)..., view, lines[user])))
            end
        end
    end
    for (write, step, start) in fill_loops(walk, flow, users, same, extent)
        filter!(((statement, _),) -> statement != write, events)
        push!(events, (step, ArrayEvent(spans[start], ArrayEventKind.write, Coverage.whole, Int[], path_of(start), nothing, nothing, nothing, false, lines[step])))
    end
    sort!(events; by = ((statement, event),) -> (event.order, statement))
    dimensions = isnothing(sizes) ? nothing : constant_dimensions(walk, something(sizes))
    pair = kind == AllocationKind.broadcast ? rebind_pair(walk, flow, users, spans, written, index, block) : nothing
    return ArrayLife(spans[index], lines[index], kind, dimensions, ArrayEvent[event for (_, event) in events], pair)
end

"""Arrays that unit `walk` allocates (`lifecycle.md`), with source statement (`lines`) and span (`spans`) of each IR statement."""
function unit_arrays(walk::Walk, lines::AbstractVector{<:Integer}, spans::AbstractVector{Span})::Vector{ArrayLife}
    Base.require_one_based_indexing(lines, spans)
    found = Tuple{Int, Tuple{AllocationKind.T, Any, Vector{Any}}}[]
    for index in 1:length(walk.ir.stmts)
        allocated = allocation(walk, index)
        isnothing(allocated) || push!(found, (index, something(allocated)))
    end
    isempty(found) && return ArrayLife[]
    flow, users, written = unit_flow(walk.ir), statement_users(walk.ir), written_roots(walk)
    return ArrayLife[array_life(walk, flow, users, lines, spans, written, index, allocated...) for (index, allocated) in found]
end
