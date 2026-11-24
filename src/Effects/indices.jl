# Index proof of `one-based-range` (F36; `types.md`, Index proof): index into array with offset axes comes from them.

using ..StandIns: StandIns
using OffsetArrays: OffsetArray

"""Root of absolute index: literal, `length`, `size`, `enumerate` counter. It indexes no array."""
struct Absolute end

"""
Root of index argument `argument` (position among method parameters): caller proves it, so method trusts it. Argument
0: arithmetic of several index arguments (`i + delta`), so no contract names one.
"""
struct Trusted
    argument::Int
end

"""
Claim that part of IR value indexes array `root` (`underlying` value with same axes; `Absolute` or `Trusted`).
`dimension`: 0 for linear or Cartesian index, `d` for dimension `d`. `path` leads from value to index: 0 takes element,
`k > 0` takes tuple field `k`.
"""
struct Claim
    root::Any
    dimension::Int
    path::Tuple{Vararg{Int}}
end

"""Claims of one IR value."""
const Claims = Set{Claim}

"""Functions whose result has axes of their only array operand."""
const SAME_AXES = Base.IdSet{Any}(Any[similar, copy, zero, deepcopy])

"""Functions whose result is index of array operand."""
const FOUND_INDEX = Base.IdSet{Any}(Any[findfirst, findlast, findnext, findprev, argmin, argmax, searchsortedfirst, searchsortedlast])

"""Functions whose result is collection of indices of array operand."""
const FOUND_INDICES = Base.IdSet{Any}(Any[findall, searchsorted, sortperm])

"""Functions whose result collects indices of array operand: element is index."""
const INDEX_COLLECTIONS = Base.IdSet{Any}(Any[eachindex, keys, LinearIndices, CartesianIndices])

"""Indexing calls: array operand, then position of first index operand."""
const INDEXING = IdDict{Any, Int}(getindex => 2, view => 2, Base.maybeview => 2, Base.dotview => 2, setindex! => 3)

"""Integer arithmetic whose result is absolute number when operands have origin."""
const ARITHMETIC = Base.IdSet{Any}(Any[*, div, (÷), fld, cld, rem, mod, (>>), (>>>), (<<)])

"""Dimension count of array `type`, or `nothing` when open: free `N`, union members that differ, or no array."""
function dimension_count(@nospecialize(type::Any))::Union{Nothing, Int}
    type isa Type || return nothing
    (type !== Union{} && type <: AbstractArray) || return nothing
    body = Base.unwrap_unionall(type)
    if body isa Union
        count = dimension_count(Base.rewrap_unionall(body.a, type))
        return count == dimension_count(Base.rewrap_unionall(body.b, type)) ? count : nothing
    end
    while Base.typename(body) !== Base.typename(AbstractArray)
        body = supertype(body)
    end
    count = body.parameters[2]
    return count isa Int ? count : nothing
end

"""Whether value of `type` is array whose axes can start anywhere: inferred `axes` type is not `OneTo` in every dimension."""
function offset_axes!(cache::IdDict{Any, Bool}, @nospecialize(type::Any))::Bool
    type isa Type || return false
    (type !== Union{} && type <: AbstractArray) || return false
    return get!(cache, type) do
        axes_type = Base.infer_return_type(axes, Tuple{type})  # corset: allow inference-dependent -- inferred axes type decides proof need by design
        !(axes_type !== Union{} && axes_type <: Tuple{Vararg{Base.OneTo}})
    end
end

"""Claims with array roots, which prove index; `Absolute` and `Trusted` claims say where index came from."""
real_claims(claims::AbstractSet{Claim})::Claims = Claims(claim for claim in claims if !(claim.root isa Union{Absolute, Trusted}))

"""Claims of `claims` whose path starts with `step`, with that step dropped."""
stepped(claims::AbstractSet{Claim}, step::Integer)::Claims = Claims(Claim(claim.root, claim.dimension, Base.tail(claim.path)) for claim in claims if !isempty(claim.path) && first(claim.path) == step)

"""Claims of `claims` with `step` put before their path."""
prefixed(claims::AbstractSet{Claim}, step::Integer)::Claims = Claims(Claim(claim.root, claim.dimension, (step, claim.path...)) for claim in claims)

"""Claims of `claims` on value itself (empty path)."""
scalar(claims::AbstractSet{Claim})::Claims = Claims(claim for claim in claims if isempty(claim.path))

"""
Origin claim of arithmetic on operands with `claims`: `Trusted` when one operand is index argument (`Trusted(0)` for
several), `Absolute` when all have origin; none when one operand has unknown origin.
"""
function origin(claims::AbstractVector{Claims})::Claims
    any(isempty ∘ scalar, claims) && return Claims()
    # Loop: nested generator iterates `Iterators.Flatten`, whose size methods packages invalidate.
    trusted = Claims()
    for operand in claims, claim in scalar(operand)
        claim.root isa Trusted && push!(trusted, claim)
    end
    isempty(trusted) && return Claims([Claim(Absolute(), 0, ())])
    return length(trusted) == 1 ? trusted : Claims([Claim(Trusted(0), 0, ())])
end

"""Whether `claims` hold claim of index argument (`Trusted`)."""
trusted_index(claims::AbstractSet{Claim})::Bool = any(claim -> claim.root isa Trusted, scalar(claims))

"""
Claims of value that is one of operands with `claims` (`min`, range bound): array claims every operand shares, where
index argument matches any array (`min(i, lastindex(x))` indexes `x`). `Trusted` only when every operand is index
argument: absolute operand can be result (`1:i`).
"""
function choice_claims(claims::AbstractVector{Claims})::Claims
    others = Claims[real_claims(scalar(operand)) for operand in claims if !(trusted_index(operand) && isempty(real_claims(scalar(operand))))]
    found = origin(claims)
    isempty(others) && return found
    trusted_index(found) && (found = Claims([Claim(Absolute(), 0, ())]))
    # Loop, since splat `intersect(others...)` infers through code that `IteratorSize` methods of other sets invalidate.
    shared = copy(first(others))
    for operand in others
        intersect!(shared, operand)
    end
    return union!(shared, found)
end

"""State of index proof over one unit: claims per IR statement (`nothing`: not computed), same-axes root of values."""
struct Proof
    walk::Walk
    claims::Vector{Union{Nothing, Claims}}
    roots::Dict{Any, Any}
    offsets::IdDict{Any, Bool}
end

"""Array root of IR `operand` in `proof`: `underlying` value, or root whose axes it shares."""
function root(proof::Proof, @nospecialize(operand::Any))::Any
    value = underlying(proof.walk, operand)
    return get(proof.roots, value, value)
end

"""Claims of IR `operand` in `proof`: statement claims, literal integer is absolute, integer argument is trusted."""
function operand_claims(proof::Proof, @nospecialize(operand::Any))::Claims
    operand isa Core.SSAValue && return something(proof.claims[operand.id], Claims())
    type = operand_type(proof.walk, operand)
    if operand isa Core.Argument
        type <: Union{Integer, CartesianIndex} && return Claims([Claim(Trusted(operand.n - 1), 0, ())])
        type <: Union{AbstractArray{<:Integer}, AbstractArray{<:CartesianIndex}} && return Claims([Claim(Trusted(operand.n - 1), 0, (0,))])
        return Claims()
    end
    constant = constant_value(proof.walk, operand)
    return constant isa Integer && !(constant isa Bool) ? Claims([Claim(Absolute(), 0, ())]) : Claims()
end

"""Index claims on array `operand` in `proof` at `path`: linear, and first dimension of vector."""
function index_claims(proof::Proof, @nospecialize(operand::Any), path::Tuple{Vararg{Integer}})::Claims
    array = root(proof, operand)
    dimensions = dimension_count(operand_type(proof.walk, operand)) == 1 ? (0, 1) : (0,)
    return Claims(Claim(array, dimension, path) for dimension in dimensions)
end

"""Array operands of `operands` in `proof`."""
arrays(proof::Proof, operands::AbstractVector{Any})::Vector{Any} = Any[operand for operand in operands if operand_type(proof.walk, operand) <: AbstractArray]

"""Claims of φ node: claims every computed incoming value shares; `nothing` before any is computed."""
function phi_claims(proof::Proof, phi::Core.PhiNode)::Union{Nothing, Claims}
    found = nothing
    for edge in eachindex(phi.values)
        isassigned(phi.values, edge) || continue
        value = phi.values[edge]
        value isa Core.SSAValue && isnothing(proof.claims[value.id]) && continue
        claims = operand_claims(proof, value)
        found = isnothing(found) ? claims : intersect(found, claims)
    end
    return found
end

"""Claims of statement `index` in `proof`; records axes `root` of its result when result shares axes of operand."""
function statement_claims!(proof::Proof, index::Integer)::Union{Nothing, Claims}
    statement = proof.walk.ir.stmts[index][:stmt]
    statement isa Core.PiNode && return operand_claims(proof, statement.val)
    statement isa Core.PhiNode && return phi_claims(proof, statement)
    statement isa Expr || return Claims()
    statement.head === :call || return Claims()
    callee, operands = call_parts(proof.walk, statement)
    isnothing(operands) && return Claims()
    shared = shared_root(proof, callee, operands)
    isnothing(shared) || (proof.roots[Core.SSAValue(index)] = something(shared))
    return call_claims(proof, callee, operands)
end

"""Axes root that result of call of `callee` on `operands` shares: `similar(x)`, broadcast of one array with scalars."""
function shared_root(proof::Proof, @nospecialize(callee::Any), operands::AbstractVector{Any})::Union{Nothing, Some{Any}}
    Base.require_one_based_indexing(operands)
    if callee in SAME_AXES
        isempty(operands) && return nothing
        operand_type(proof.walk, operands[1]) <: AbstractArray || return nothing
        # `similar(x, T)` keeps axes; `similar(x, n)` makes new ones.
        all(operand -> operand_type(proof.walk, operand) <: Type, operands[2:end]) || return nothing
        return Some{Any}(root(proof, operands[1]))
    end
    callee === Broadcast.materialize || return nothing
    found = broadcast_arrays(proof, operands[1])
    return isnothing(found) || length(found) != 1 ? nothing : Some{Any}(only(found))
end

"""Array roots that broadcast `operand` in `proof` combines; `nothing` when operand is no broadcast of arrays and scalars."""
function broadcast_arrays(proof::Proof, @nospecialize(operand::Any))::Union{Nothing, Set{Any}}
    type = operand_type(proof.walk, operand)
    type <: Union{Number, Ref, Base.RefValue} && return Set{Any}()
    type <: AbstractArray && return Set{Any}([root(proof, operand)])
    value = underlying(proof.walk, operand)
    value isa Core.SSAValue || return nothing
    statement = proof.walk.ir.stmts[value.id][:stmt]
    statement isa Expr || return nothing
    statement.head === :call || return nothing
    callee, operands = call_parts(proof.walk, statement)
    (callee === Broadcast.broadcasted && !isnothing(operands)) || return nothing
    found = Set{Any}()
    for part in operands[2:end]
        roots = broadcast_arrays(proof, part)
        isnothing(roots) && return nothing
        union!(found, roots)
    end
    return found
end

"""Claims of result of call of `callee` on `operands` in `proof`."""
function call_claims(proof::Proof, @nospecialize(callee::Any), operands::AbstractVector{Any})::Claims
    Base.require_one_based_indexing(operands)
    isempty(operands) && return Claims()
    first_operand, count = operands[1], length(operands)
    callee in (identity, typeassert) && return operand_claims(proof, first_operand)
    callee === convert && count == 2 && return operand_claims(proof, operands[2])
    callee isa Type && callee <: Integer && count == 1 && return scalar(operand_claims(proof, first_operand))
    callee in (firstindex, lastindex) && return count == 1 ? index_claims(proof, first_operand, ()) : dimension_claims(proof, operands, ())
    callee in INDEX_COLLECTIONS && return union(Claims(), (index_claims(proof, array, (0,)) for array in arrays(proof, operands))...)
    callee === pairs && count == 1 && return index_claims(proof, first_operand, (0, 1))
    callee === axes && return count == 1 ? axes_claims(proof, first_operand) : dimension_claims(proof, operands, (0,))
    # `argmax(f, domain)` gives element of domain, not index.
    callee in (argmin, argmax) && count != 1 && return Claims()
    callee in FOUND_INDEX && return found_claims(proof, operands, ())
    callee in FOUND_INDICES && return found_claims(proof, operands, (0,))
    callee in (findmax, findmin) && return found_claims(proof, operands, (2,))
    callee in (length, size, ndims) && return absolute_claims(proof, callee, operands)
    callee === iterate && return prefixed(stepped(operand_claims(proof, first_operand), 0), 1)
    callee === Base.indexed_iterate && return field_claims(proof, first_operand, constant_value(proof.walk, operands[2]), true)
    callee === getfield && count >= 2 && return field_claims(proof, first_operand, constant_value(proof.walk, operands[2]), false)
    callee in (first, last) && return end_claims(proof, callee, first_operand)
    callee in (reverse, collect, Iterators.reverse) && count == 1 && return Claims(claim for claim in operand_claims(proof, first_operand) if !isempty(claim.path))
    # `enumerate` element: absolute counter, then element of operand.
    callee === enumerate && count == 1 && return union(Claims([Claim(Absolute(), 0, (0, 1))]), prefixed(prefixed(stepped(operand_claims(proof, first_operand), 0), 2), 0))
    # `@simd` loop reads element `i` of iterated range through `simd_index`.
    callee === Base.simd_index && return stepped(operand_claims(proof, first_operand), 0)
    callee === zip && return union(Claims(), (prefixed(prefixed(stepped(operand_claims(proof, operand), 0), position), 0) for (position, operand) in enumerate(operands))...)
    callee === tuple && return union(Claims(), (prefixed(operand_claims(proof, operand), position) for (position, operand) in enumerate(operands))...)
    # `Base.OneTo(n)` starts at 1 whatever `n` is.
    callee isa Type && callee <: Base.OneTo && return Claims([Claim(Absolute(), 0, (0,))])
    callee === (:) && return range_claims(proof, count == 3 ? [first_operand, operands[3]] : operands)
    callee isa Type && callee <: AbstractUnitRange && count == 2 && return range_claims(proof, operands)
    callee in (something, ifelse, min, max, clamp) && return shared_claims(proof, callee === ifelse ? operands[2:end] : operands)
    callee in (prevind, nextind) && count == 2 && return operand_claims(proof, operands[2])
    callee in (+, -) && return sum_claims(proof, callee, operands)
    # `i ÷ 2` of index argument `i` is no index the caller proves: heap parent assumes one-based axes.
    callee in ARITHMETIC && return isempty(origin(Claims[operand_claims(proof, operand) for operand in operands])) ? Claims() : Claims([Claim(Absolute(), 0, ())])
    return Claims()
end

"""Claims on dimension of `firstindex(x, d)` or `axes(x, d)` with constant `d`, at `path`."""
function dimension_claims(proof::Proof, operands::AbstractVector{Any}, path::Tuple{Vararg{Integer}})::Claims
    Base.require_one_based_indexing(operands)
    dimension = constant_value(proof.walk, operands[2])
    dimension isa Integer || return Claims()
    return Claims([Claim(root(proof, operands[1]), Int(dimension), path)])
end

"""Claims of `axes(x)`: field `d` holds range of indices of dimension `d`."""
function axes_claims(proof::Proof, @nospecialize(array::Any))::Claims
    count = dimension_count(operand_type(proof.walk, array))
    isnothing(count) && return Claims()
    return Claims(Claim(root(proof, array), dimension, (dimension, 0)) for dimension in 1:count)
end

"""Claims of search result of first array operand at `path`: `findfirst(pred, x)` indexes `x`."""
function found_claims(proof::Proof, operands::AbstractVector{Any}, path::Tuple{Vararg{Integer}})::Claims
    found = arrays(proof, operands)
    return isempty(found) ? Claims() : index_claims(proof, first(found), path)
end

"""`length(x)`, `size(x, d)` and `ndims(x)` are absolute; `size(x)` holds absolute count in each field."""
function absolute_claims(proof::Proof, @nospecialize(callee::Any), operands::AbstractVector{Any})::Claims
    Base.require_one_based_indexing(operands)
    (callee !== size || length(operands) == 2) && return Claims([Claim(Absolute(), 0, ())])
    count = dimension_count(operand_type(proof.walk, operands[1]))
    return isnothing(count) ? Claims() : Claims(Claim(Absolute(), 0, (dimension,)) for dimension in 1:count)
end

"""Claims of field `field` of `operand`; destructuring (`indexed_iterate`) puts field in tuple with state."""
function field_claims(proof::Proof, @nospecialize(operand::Any), @nospecialize(field::Any), destructured::Bool)::Claims
    position = field === :first ? 1 : field === :second ? 2 : field
    position isa Integer || return Claims()
    claims = operand_claims(proof, operand)
    found = stepped(claims, position)
    # Destructuring range of indices takes element.
    destructured && union!(found, stepped(claims, 0))
    return destructured ? prefixed(found, 1) : found
end

"""Claims of `first(x)` or `last(x)`: tuple or pair gives field, collection gives element. Tuple of open length gives none for `last`."""
function end_claims(proof::Proof, @nospecialize(callee::Any), @nospecialize(operand::Any))::Claims
    claims, type = operand_claims(proof, operand), operand_type(proof.walk, operand)
    type <: Union{Tuple, Pair} || return stepped(claims, 0)
    callee === first && return stepped(claims, 1)
    count = type <: Pair ? 2 : type isa DataType && !Base.isvatuple(type) ? fieldcount(type) : nothing
    return isnothing(count) ? Claims() : stepped(claims, count)
end

"""Claims of range between `bounds`: element indexes array both bounds index; origin of bounds otherwise."""
function range_claims(proof::Proof, bounds::AbstractVector{Any})::Claims
    return prefixed(choice_claims(Claims[operand_claims(proof, bound) for bound in bounds]), 0)
end

"""Claims every operand of `operands` shares, as of `min` or `something`; `nothing` operand of `something` passes."""
function shared_claims(proof::Proof, operands::AbstractVector{Any})::Claims
    kept = Any[operand for operand in operands if !(operand_type(proof.walk, operand) <: Nothing)]
    isempty(kept) && return Claims()
    return choice_claims(Claims[operand_claims(proof, operand) for operand in kept])
end

"""
Claims of `+` or `-`: index plus or minus offset stays index; index minus index is offset. Sum of two indices is no
index: it overflows on axes near `typemin`, so midpoint is `lo + (hi - lo) ÷ 2`.
"""
function sum_claims(proof::Proof, @nospecialize(callee::Any), operands::AbstractVector{Any})::Claims
    length(operands) == 2 || return Claims()
    left, right = (operand_claims(proof, operand) for operand in operands)
    real_left, real_right = real_claims(scalar(left)), real_claims(scalar(right))
    found = origin([left, right])
    isempty(real_right) && union!(found, real_left)
    callee === (+) && isempty(real_left) && union!(found, real_right)
    return found
end

"""Rounds of claim propagation: each round carries claims over one more loop back edge."""
const ROUNDS = 16

"""
Index facts of unit `walk` of `method` inferred with offset stand-ins (`types.md`, Index proof): indices into arrays
with offset axes that have no proof, contracts of index arguments, and package calls that pass arrays with offset axes.
`lines` gives source statement of each IR statement, `spans` span of each source statement. One unproven fact per
indexing call: its first unproven index. Call compiler inserts gives none. Blind spots come from `index_contracts`.
"""
function index_facts(walk::Walk, method::Method, lines::AbstractVector{<:Integer}, spans::AbstractVector{Span})::Tuple{IndexFacts, Vector{BlindSpot}}
    Base.require_one_based_indexing(lines, spans)
    span_of(index::Integer)::Union{Nothing, Span} = lines[index] in eachindex(spans) ? spans[lines[index]] : nothing
    count = length(walk.ir.stmts)
    proof = Proof(walk, Vector{Union{Nothing, Claims}}(nothing, count), Dict{Any, Any}(), IdDict{Any, Bool}())
    for _ in 1:ROUNDS
        changed = false
        for index in 1:count
            claims = statement_claims!(proof, index)
            isequal(claims, proof.claims[index]) && continue
            proof.claims[index], changed = claims, true
        end
        changed || break
    end
    domtree, guards, agreements = CC.construct_domtree(walk.ir.cfg.blocks), one_based_guards(proof), axes_agreements(proof)
    found, contracts, calls, spots = UnprovenIndex[], IndexContract[], IndexCall[], BlindSpot[]
    for index in 1:count
        site = span_of(index)
        isnothing(site) && continue
        site_contracts, site_spots = index_contracts(proof, domtree, guards, agreements, index, site)
        append!(contracts, site_contracts); append!(spots, site_spots)
        call = index_call(proof, domtree, guards, agreements, index)
        isnothing(call) || push!(calls, IndexCall(site, call...))
        # Index from several arguments to package call: callee contract names one argument, so it checks none.
        several = !isnothing(call) && any(claim -> claim.source == IndexSource.parameter && claim.target == 0, last(something(call)))
        several && push!(spots, BlindSpot(SEVERAL_ARGUMENTS, site))
        unproven_site = unproven(proof, domtree, guards, agreements, index)
        isnothing(unproven_site) && continue
        array, operand, confidence = unproven_site
        source = underlying(walk, operand)
        cause = source isa Core.SSAValue ? span_of(source.id) : nothing
        push!(found, UnprovenIndex(site, cause == site ? nothing : cause, value_text(walk, method, array), confidence))
    end
    return IndexFacts(unique!(found), unique!(contracts), calls), unique!(spots)
end

"""Calls `Base.require_one_based_indexing(x...)` in `proof`: statement and root of each array it checks."""
function one_based_guards(proof::Proof)::Vector{Tuple{Int, Any}}
    found = Tuple{Int, Any}[]
    for index in 1:length(proof.walk.ir.stmts)
        parts = call_of(proof.walk, Core.SSAValue(index))
        isnothing(parts) && continue
        callee, operands = parts
        callee === Base.require_one_based_indexing || continue
        append!(found, ((index, root(proof, operand)) for operand in arrays(proof, operands)))
    end
    return found
end

"""
Agreements of axes in `proof`: branch on `axes(x) == axes(y)` (or `!=`) whose other side throws. Gives block that runs
only when axes agree, and roots of both arrays.
"""
function axes_agreements(proof::Proof)::Vector{Tuple{Int, Any, Any}}
    ir, found = proof.walk.ir, Tuple{Int, Any, Any}[]
    for (block, info) in enumerate(ir.cfg.blocks)
        branch = ir.stmts[last(info.stmts)][:stmt]
        branch isa Core.GotoIfNot || continue
        compared = compared_axes(proof, branch.cond)
        isnothing(compared) && continue
        equal, left, right = compared
        # Branch jumps to `dest` when condition is false and falls through to next block when true.
        agree, other = equal ? (block + 1, branch.dest) : (branch.dest, block + 1)
        throws(ir, other) && push!(found, (agree, left, right))
    end
    return found
end

"""Comparison `axes(x) == axes(y)` or `!=` that `condition` is: whether it tests equality, and both array roots."""
function compared_axes(proof::Proof, @nospecialize(condition::Any))::Union{Nothing, Tuple{Bool, Any, Any}}
    parts = call_of(proof.walk, condition)
    isnothing(parts) && return nothing
    callee, operands = parts
    (callee in (==, isequal, !=) && length(operands) == 2) || return nothing
    roots = Any[]
    for operand in operands
        inner = call_of(proof.walk, operand)
        isnothing(inner) && return nothing
        (first(inner) === axes && length(last(inner)) == 1) || return nothing
        push!(roots, root(proof, only(last(inner))))
    end
    return (callee !== (!=), roots[1], roots[2])
end

"""Callee and operands of call that IR `operand` of `walk` is, after `π` nodes; `nothing` for other value."""
function call_of(walk::Walk, @nospecialize(operand::Any))::Union{Nothing, Tuple{Any, Vector{Any}}}
    value = underlying(walk, operand)
    value isa Core.SSAValue || return nothing
    statement = walk.ir.stmts[value.id][:stmt]
    statement isa Expr || return nothing
    statement.head === :call || return nothing
    callee, operands = call_parts(walk, statement)
    return isnothing(operands) ? nothing : (callee, operands)
end

"""Whether `block` of `ir` ends in `unreachable`: code there throws."""
function throws(ir::CC.IRCode, block::Integer)::Bool
    statement = ir.stmts[last(ir.cfg.blocks[block].stmts)][:stmt]
    return statement isa Core.ReturnNode && !isdefined(statement, :val)
end

"""
Indexing call at statement `index` of `proof` into array whose axes can start anywhere, with no one-based guard
(`guards`, `domtree`) before it: array operand, its root, block of call, index operands and dimension count of array.
"""
function offset_indexing(proof::Proof, domtree::CC.DomTree, guards::AbstractVector{<:Tuple{Integer, Any}}, index::Integer)::Union{Nothing, Tuple{Any, Any, Int, Vector{Any}, Union{Nothing, Int}}}
    parts = call_of(proof.walk, Core.SSAValue(index))
    isnothing(parts) && return nothing
    callee, operands = parts
    start = get(INDEXING, callee, 0)
    (start > 0 && length(operands) >= start - 1) || return nothing
    array = operands[1]
    type = operand_type(proof.walk, array)
    # Array of declared abstract type (field `data::AbstractVector`) has no stand-in; rule checks stand-ins only.
    (holds_stand_in(type) && offset_axes!(proof.offsets, type)) || return nothing
    array_root = root(proof, array)
    guarded(proof, domtree, guards, array_root, index) && return nothing
    return array, array_root, CC.block_for_inst(proof.walk.ir.cfg, index), operands[start:end], dimension_count(type)
end

"""Whether one-based guard of `guards` checks array `array_root` before statement `index` of `proof` on every path."""
function guarded(proof::Proof, domtree::CC.DomTree, guards::AbstractVector{<:Tuple{Integer, Any}}, @nospecialize(array_root::Any), index::Integer)::Bool
    return any(((at, checked),) -> checked == array_root && dominates_statement(proof.walk.ir, domtree, at, index), guards)
end

"""Whether index `operand` of `proof` selects no element by position: colon or `Bool` mask."""
selects_all(proof::Proof, @nospecialize(operand::Any))::Bool = operand_type(proof.walk, operand) <: Union{Colon, AbstractArray{Bool}}

"""
Unproven index of indexing call at statement `index` in `proof`: array operand, index operand and certainty. Absolute
index (literal, `length`, counter, index of other array) is `definite`; unknown source `possible`. Index argument and
array after one-based guard pass.
"""
function unproven(proof::Proof, domtree::CC.DomTree, guards::AbstractVector{<:Tuple{Integer, Any}}, agreements::AbstractVector{<:Tuple{Integer, Any, Any}}, index::Integer)::Union{Nothing, Tuple{Any, Any, Confidence.T}}
    parts = offset_indexing(proof, domtree, guards, index)
    isnothing(parts) && return nothing
    array, array_root, block, indices, dimensions = parts
    for (position, operand) in enumerate(indices)
        selects_all(proof, operand) && continue
        claims = operand_claims(proof, operand)
        any(claim -> proves(proof, domtree, agreements, claim, array_root, block, position, length(indices), dimensions), claims) && continue
        any(claim -> claim.root isa Trusted, claims) && continue
        return (array, operand, isempty(claims) ? Confidence.possible : Confidence.definite)
    end
    return nothing
end

"""Blind spot cause of index from arithmetic of several arguments: contract names one argument, so callers check none."""
const SEVERAL_ARGUMENTS = "index from several arguments"

"""
Contracts that indexing call at statement `index` of `proof`, span `site`, asks of callers: index argument without
other proof indexes array argument (`types.md`, Index proof). Index from several arguments gives blind spot instead.
"""
function index_contracts(proof::Proof, domtree::CC.DomTree, guards::AbstractVector{<:Tuple{Integer, Any}}, agreements::AbstractVector{<:Tuple{Integer, Any, Any}}, index::Integer, site::Span)::Tuple{Vector{IndexContract}, Vector{BlindSpot}}
    parts = offset_indexing(proof, domtree, guards, index)
    isnothing(parts) && return IndexContract[], BlindSpot[]
    _, array_root, block, indices, dimensions = parts
    array_root isa Core.Argument || return IndexContract[], BlindSpot[]
    found, spots = IndexContract[], BlindSpot[]
    for (position, operand) in enumerate(indices)
        selects_all(proof, operand) && continue
        claims = operand_claims(proof, operand)
        any(claim -> proves(proof, domtree, agreements, claim, array_root, block, position, length(indices), dimensions), claims) && continue
        for claim in claims
            source = claim.root
            source isa Trusted || continue
            source.argument == 0 && (push!(spots, BlindSpot(SEVERAL_ARGUMENTS, site)); continue)
            claim.path in ((), (0,)) || continue
            push!(found, IndexContract(source.argument, claim.path == (0,), array_root.n - 1, position, length(indices), site))
        end
    end
    return found, spots
end

"""
Package call at statement `index` of `proof` with array operand whose axes can start anywhere and no one-based guard
before it (`IndexCall` parts): signatures of package methods it can run, such array operands, and index claims of
operands. Index of array with axes of no array operand is index of other array. Keyword call runs keyword sorter, whose
parameters differ from body: it gives none.
"""
function index_call(proof::Proof, domtree::CC.DomTree, guards::AbstractVector{<:Tuple{Integer, Any}}, agreements::AbstractVector{<:Tuple{Integer, Any, Any}}, index::Integer)::Union{Nothing, Tuple{Vector{Type}, Vector{ArrayOperand}, Vector{OperandIndex}}}
    statement = proof.walk.ir.stmts[index][:stmt]
    statement isa Expr || return nothing
    statement.head === :call || return nothing
    constant_value(proof.walk, statement.args[1]) === Core.kwcall && return nothing
    _, operands = call_parts(proof.walk, statement)
    isnothing(operands) && return nothing
    matches = call_matches(proof.walk, statement)
    isnothing(matches) && return nothing
    callees = Type[match.method.sig for match in matches if match.method.module in proof.walk.modules]
    isempty(callees) && return nothing
    arrays = ArrayOperand[]
    for (position, operand) in enumerate(operands)
        type = operand_type(proof.walk, operand)
        (holds_stand_in(type) && offset_axes!(proof.offsets, type)) || continue
        array_root = root(proof, operand)
        guarded(proof, domtree, guards, array_root, index) && continue
        push!(arrays, ArrayOperand(position, dimension_count(type), array_root isa Core.Argument ? array_root.n - 1 : 0))
    end
    isempty(arrays) && return nothing
    claims, block = OperandIndex[], CC.block_for_inst(proof.walk.ir.cfg, index)
    for (position, operand) in enumerate(operands), claim in operand_claims(proof, operand)
        claim.path in ((), (0,)) || continue
        element, source = claim.path == (0,), claim.root
        if source isa Trusted
            push!(claims, OperandIndex(position, element, IndexSource.parameter, source.argument, 0))
        elseif source isa Absolute
            push!(claims, OperandIndex(position, element, IndexSource.absolute, 0, 0))
        else
            indexed = [array.operand for array in arrays if same_axes(domtree, agreements, source, root(proof, operands[array.operand]), block)]
            isempty(indexed) && push!(claims, OperandIndex(position, element, IndexSource.other, 0, claim.dimension))
            append!(claims, (OperandIndex(position, element, IndexSource.array, target, claim.dimension) for target in indexed))
        end
    end
    return callees, arrays, unique!(claims)
end

"""Whether statement `guard` of `ir` runs before statement `index` on every path."""
function dominates_statement(ir::CC.IRCode, domtree::CC.DomTree, guard::Integer, index::Integer)::Bool
    first_block, second_block = CC.block_for_inst(ir.cfg, guard), CC.block_for_inst(ir.cfg, index)
    first_block == second_block && return guard < index
    return CC.dominates(domtree, first_block, second_block)
end

"""
Whether `claim` proves index at `position` of `count` indices into array `array_root` with `dimensions`, in `block`:
same axes, index or range of indices, and dimension that position addresses.
"""
function proves(proof::Proof, domtree::CC.DomTree, agreements::AbstractVector{<:Tuple{Integer, Any, Any}}, claim::Claim, @nospecialize(array_root::Any), block::Integer, position::Integer, count::Integer, dimensions::Union{Nothing, Integer})::Bool
    claim.path in ((), (0,)) || return false
    dimension_matches = count == 1 ? claim.dimension == 0 || (claim.dimension == 1 && dimensions == 1) : claim.dimension == position
    return dimension_matches && same_axes(domtree, agreements, claim.root, array_root, block)
end

"""Whether array roots `left` and `right` share axes in `block`: same root, or axes agreement of `agreements` runs first."""
function same_axes(domtree::CC.DomTree, agreements::AbstractVector{<:Tuple{Integer, Any, Any}}, @nospecialize(left::Any), @nospecialize(right::Any), block::Integer)::Bool
    left == right && return true
    return any(((agree, one, other),) -> Set{Any}([one, other]) == Set{Any}([left, right]) && CC.dominates(domtree, agree, block), agreements)
end

"""
`type` with each array stand-in `A` replaced by `OffsetArray` of `A`, in parameters and union members too. Parametric
type whose bound rejects offset array keeps its stand-in.
"""
function offset_type(@nospecialize(type::Any))::Any
    type isa Union && return Union{offset_type(type.a), offset_type(type.b)}
    if type isa UnionAll
        body = offset_type(type.body)
        return body === type.body ? type : UnionAll(type.var, body)
    end
    type isa DataType || return type
    StandIns.array_stand_in(type) && return OffsetArray{type.parameters[1], type.parameters[2], type}
    parameters = Any[offset_type(parameter) for parameter in type.parameters]
    all(((new, old),) -> new === old, zip(parameters, type.parameters)) && return type
    try
        return type.name.wrapper{parameters...}
    catch exception
        exception isa TypeError || rethrow()
        return type
    end
end

"""
Unit `signature` with offset stand-in in place of each array stand-in that `method` accepts there; `nothing` when no
argument changes. Arguments that share type variable of method (`x::T, y::T`) change only together: each group of
rejected ones tries at once.
"""
function offset_signature(method::Method, signature::Type)::Union{Nothing, Type}
    parameters, rejected = Any[Base.unwrap_unionall(signature).parameters...], Int[]
    accepts(candidate::AbstractVector)::Bool = typeintersect(Base.rewrap_unionall(Tuple{candidate...}, signature), method.sig) !== Union{}
    offsets = Any[offset_type(parameter) for parameter in parameters]
    changed = false
    for position in eachindex(parameters)
        offsets[position] === parameters[position] && continue
        candidate = copy(parameters)
        candidate[position] = offsets[position]
        accepts(candidate) || (push!(rejected, position); continue)
        parameters, changed = candidate, true
    end
    for group in shared_groups(method, rejected)
        together = copy(parameters)
        together[group] = offsets[group]
        if length(group) > 1 && accepts(together)
            parameters, changed = together, true
        end
    end
    return changed ? Base.rewrap_unionall(Tuple{parameters...}, signature) : nothing
end

"""Blind spot cause of unit that indexes but gives no code with offset stand-in."""
const OFFSET_UNINFERRED = "offset stand-in gave no code"

"""Blind spot cause of unit whose offset inference crashed process in earlier run of crash journal."""
const OFFSET_CRASHED = "offset inference crashed process"

"""Blind spot cause of generated method whose generator gives other code for offset stand-in: spans do not fit it."""
const OFFSET_UNMAPPED = "generator gave other code for offset stand-in"

"""
Groups of argument `positions` of `method` linked through type variables their declared types share. Variable bounded by
other variable (`S <: T`) links to it.
"""
function shared_groups(method::Method, positions::AbstractVector{<:Integer})::Vector{Vector{Int}}
    variables, body = TypeVar[], method.sig
    while body isa UnionAll
        push!(variables, body.var)
        body = body.body
    end
    declared = Base.unwrap_unionall(method.sig).parameters
    shared = Dict{Int, Vector{TypeVar}}()
    for position in positions
        type = Base.unwrapva(declared[min(position, length(declared))])
        found = TypeVar[variable for variable in variables if Base.has_typevar(type, variable)]
        index = 1
        while index <= length(found)
            bounds = found[index]
            append!(found, (variable for variable in variables if !(variable in found) && (Base.has_typevar(bounds.ub, variable) || Base.has_typevar(bounds.lb, variable))))
            index += 1
        end
        shared[position] = found
    end
    groups, left = Vector{Int}[], collect(Int, positions)
    while !isempty(left)
        group, pending = Int[], [popfirst!(left)]
        while !isempty(pending)
            position = pop!(pending)
            push!(group, position)
            linked = Int[other for other in left if !isempty(intersect(shared[position], shared[other]))]
            filter!(other -> !(other in linked), left)
            append!(pending, linked)
        end
        push!(groups, group)
    end
    return groups
end

"""Whether typed code of unit `walk` indexes array whose type holds stand-in."""
function indexes_stand_in(walk::Walk)::Bool
    for index in 1:length(walk.ir.stmts)
        parts = call_of(walk, Core.SSAValue(index))
        isnothing(parts) && continue
        callee, operands = parts
        haskey(INDEXING, callee) && !isempty(operands) && holds_stand_in(operand_type(walk, operands[1])) && return true
    end
    return false
end

"""
Whether typed code of `walk` calls with array stand-in operand function that can run package method (method package
adds to `Base` function included): call may owe index contract.
"""
function passes_stand_in(walk::Walk)::Bool
    for index in 1:length(walk.ir.stmts)
        statement = walk.ir.stmts[index][:stmt]
        statement isa Expr || continue
        statement.head === :call || continue
        _, operands = call_parts(walk, statement)
        isnothing(operands) && continue
        any(operand -> (type = operand_type(walk, operand); type <: AbstractArray && holds_stand_in(type)), operands) || continue
        matches = call_matches(walk, statement)
        !isnothing(matches) && any(match -> match.method.module in walk.modules, matches) && return true
    end
    return false
end

"""
Whether lowered code of `method` passes array argument whose `signature` type holds stand-in to function of `modules`
or function they add method to. Typed code can miss call, as `lowered_indexing` explains. Aliases (`g = f`, `ys = xs`)
count.
"""
function lowered_passes(method::Method, @nospecialize(signature::Type), modules::AbstractSet{Module})::Bool
    isdefined(method, :source) || return true
    parameters = (Base.unwrap_unionall(signature)::DataType).parameters
    arrays = Set{Any}(Core.SlotNumber(position) for position in eachindex(parameters) if array_stand_in_type(parameters[position]))
    isempty(arrays) && return false
    code = Base.uncompressed_ast(method).code
    aliases = lowered_aliases(code)
    # Only callee that takes array resolves, so check stays cheap.
    for call in lowered_calls(code)
        any(operand -> !isdisjoint(lowered_roots(aliases, operand), arrays), call.args[2:end]) || continue
        callees = callee_globals(aliases, call.args[1], method.nargs)
        # Callee that can be call result or argument (`getfield(M, :f)(xs, 1)`) can be package function.
        isnothing(callees) && return true
        any(callee -> isdefined(callee.mod, callee.name) && package_function(getglobal(callee.mod, callee.name), modules), callees) && return true
    end
    return false
end

"""
Globals and slots that each slot or SSA value of lowered `code` can hold: function alias (`g = getindex`) and array
alias (`ys = xs`) through slot assignments, slot reads and SSA values. Call result holds slots of its operands, since
it can keep their axes (`copy(xs)`), and `COMPUTED`. Rounds run until no set grows, so loops count.
"""
function lowered_aliases(code::AbstractVector{Any})::Dict{Any, Set{Any}}
    aliases = Dict{Any, Set{Any}}()
    grown = true
    while grown
        grown = false
        for (index, statement) in enumerate(code)
            target = statement isa Expr && statement.head === :(=) ? statement.args[1] : Core.SSAValue(index)
            found = lowered_roots(aliases, statement isa Expr && statement.head === :(=) ? statement.args[2] : statement)
            isempty(found) && continue
            held = get!(Set{Any}, aliases, target)
            issubset(found, held) && continue
            union!(held, found); grown = true
        end
    end
    return aliases
end

"""Root that call result holds in `lowered_aliases`: value that no global names, as `getfield(M, :f)` gives."""
struct Computed end

"""Only `Computed` value."""
const COMPUTED = Computed()

"""
Globals and slots that lowered `operand` can hold through `aliases` (`lowered_aliases`), and `COMPUTED` for call
result; slot holds itself too.
"""
function lowered_roots(aliases::AbstractDict{Any, <:AbstractSet{Any}}, @nospecialize(operand::Any))::Set{Any}
    operand isa GlobalRef && return Set{Any}([operand])
    operand isa Core.SlotNumber && return union(Set{Any}([operand]), get(aliases, operand, Set{Any}()))
    operand isa Core.SSAValue && return get(aliases, operand, Set{Any}())
    operand isa Expr || return Set{Any}()
    operand.head === :call || return Set{Any}()
    return Set{Any}([COMPUTED; Any[root for argument in operand.args[2:end] for root in lowered_roots(aliases, argument) if root isa Core.SlotNumber]])
end

"""Call expressions of lowered `code`: call statements and calls whose value slot assignment takes (`_4 = f(x)`)."""
lowered_calls(code::AbstractVector{Any})::Vector{Expr} =
    Expr[call for statement in code for call in (statement isa Expr && statement.head === :(=) ? statement.args[2] : statement,) if call isa Expr && call.head === :call]

"""
Globals that lowered `callee` operand can be, through `aliases` (`lowered_aliases`); `nothing` when one alternative is
no global: call result, one of `arguments` first slots, or value that aliases do not follow.
"""
function callee_globals(aliases::AbstractDict{Any, <:AbstractSet{Any}}, @nospecialize(callee::Any), arguments::Integer)::Union{Nothing, Set{GlobalRef}}
    roots = lowered_roots(aliases, callee)
    globals = Set{GlobalRef}(root for root in roots if root isa GlobalRef)
    isempty(globals) && return nothing
    return any(root -> root === COMPUTED || (root isa Core.SlotNumber && root.id <= arguments), roots) ? nothing : globals
end

"""Whether signature `parameter` is array type that holds stand-in."""
array_stand_in_type(@nospecialize(parameter::Any))::Bool = parameter isa Type && parameter <: AbstractArray && holds_stand_in(parameter)

"""Whether `callee` is function of `modules`, or function they add method to."""
function package_function(@nospecialize(callee::Any), modules::AbstractSet{Module})::Bool
    callee isa Function || return false
    parentmodule(callee) in modules && return true
    return any(method -> method.module in modules, methods(callee))
end

"""
Whether lowered code of `method` calls indexing function (`INDEXING`). Typed code can miss it: inference with one-based
stand-in drops branch on `firstindex(x) == 1`. Alias (`g = getindex`) counts.
"""
function lowered_indexing(method::Method)::Bool
    # Method without source (built from `CodeInfo`) can index: infer again.
    isdefined(method, :source) || return true
    code = Base.uncompressed_ast(method).code
    aliases = lowered_aliases(code)
    indexing(callee::GlobalRef)::Bool = isdefined(callee.mod, callee.name) && haskey(INDEXING, getglobal(callee.mod, callee.name))
    # Unresolved callee counts as no indexing: function argument `f(xs)` would infer every higher-order method again.
    return any(call -> any(indexing, something(callee_globals(aliases, call.args[1], method.nargs), Set{GlobalRef}())), lowered_calls(code))
end

# corset: allow bang-convention -- crash journal records progress; caller reads it only after crash
"""
Offset inference of unit `typed` at `signature` in `world`, or blind spot cause: `OFFSET_CRASHED` when key crashed earlier
run of `journal`, `OFFSET_UNINFERRED` when inference gives no code, `OFFSET_UNMAPPED` when generator gives other code
than for unit. Journal records start and finish, as for first inference: generator can abort process on offset
stand-in. `nothing` journal records none.
"""
function offset_inference(typed::TypedCode, signature::Type, journal::Union{Nothing, Inference.Journal}, world::UInt)::Union{String, Inference.Output}
    method = typed.site.method
    key = "offset " * Inference.entry_key(method, signature)
    isnothing(journal) || !(key in journal.crashed) || return OFFSET_CRASHED
    isnothing(journal) || Inference.record!(journal, Inference.Record(key, Inference.method_label(method) * " with offset stand-in", false, nothing))
    inferred = Inference.infer(method, signature)
    # Spans of unit fit offset code only when both lower alike; generator runs again, so journal covers check.
    mapped = isnothing(inferred) || !Base.hasgenerator(method) || same_lowered(typed.frame.linfo, first(inferred), world)
    isnothing(journal) || Inference.record!(journal, Inference.Record(key, "", true, nothing))
    isnothing(inferred) && return OFFSET_UNINFERRED
    return mapped ? inferred : OFFSET_UNMAPPED
end

"""Whether instances `unit` and `offset` have equal lowered code in `world`; generated method runs its generator."""
function same_lowered(unit::Core.MethodInstance, offset::Core.MethodInstance, world::UInt)::Bool
    unit_code, offset_code = CC.retrieve_code_info(unit, world), CC.retrieve_code_info(offset, world)
    return !isnothing(unit_code) && !isnothing(offset_code) && unit_code.code == offset_code.code
end

"""
Index facts of unit `typed` with `walk` (`index_facts`), and blind spots: method infers again with offset
stand-ins (`offset_inference` with `journal`), and proof runs on that code. Method without indexing or package call
with array stand-in, in typed or lowered code, and method that rejects offset stand-ins give none. Generated method always infers again: one-based inference can
drop its indexing branch.
"""
function unit_indices(typed::TypedCode, walk::Walk, interpreter::CC.NativeInterpreter, journal::Union{Nothing, Inference.Journal})::Tuple{IndexFacts, Vector{BlindSpot}, Union{Nothing, Vector{Any}}}
    method = typed.site.method
    reaches = indexes_stand_in(walk) || passes_stand_in(walk) || lowered_indexing(method) || lowered_passes(method, typed.signature, walk.modules)
    (Base.hasgenerator(method) || reaches) || return IndexFacts(), BlindSpot[], Any[]
    signature = offset_signature(method, typed.signature)
    isnothing(signature) && return IndexFacts(), BlindSpot[], Any[]
    inferred = offset_inference(typed, signature, journal, walk.world)
    # Failed offset inference leaves its callees unknown, so store cannot check record: no edges.
    inferred isa String && return IndexFacts(), [BlindSpot(inferred, typed.site.span)], nothing
    offset_walk, lines = frame_walk(last(inferred), method, walk.modules, interpreter, walk.world)
    walk_values!(offset_walk, 2 * length(offset_walk.ir.stmts) + 10)
    return index_facts(offset_walk, method, lines, typed.spans)..., inferred[4]
end
