# Base interface contracts for calls with unresolved dispatch. Positions count operands; 1 is callee, 2 first argument.
# `rest` in a range end stands for last operand.

const REST = typemax(Int)

"""Documented effect of generic Base function: written operands, stores, result aliases, fresh result."""
Base.@kwdef struct Contract
    writes::Vector{Int} = Int[]
    stores::Vector{Tuple{Int, UnitRange{Int}}} = Tuple{Int, UnitRange{Int}}[]  # operand objects become content
    shares::Vector{Tuple{Int, UnitRange{Int}}} = Tuple{Int, UnitRange{Int}}[]  # operand elements become content
    same::UnitRange{Int} = 1:0
    inside::UnitRange{Int} = 1:0
    contains::UnitRange{Int} = 1:0
    overlap::UnitRange{Int} = 1:0
    fresh::Bool = false
end

const PURE = Contract(; fresh = true)

const CONTRACTS = IdDict{Any, Contract}()

for f in (
        +, -, *, /, \, ^, ==, !=, <, <=, >, >=, isless, isequal, hash, cmp, length, size, axes, ndims, zero, one,
        oneunit, typemin, typemax, abs, abs2, sqrt, cbrt, log, log2, log10, log1p, exp, exp2, expm1, sin, cos, tan,
        atan, rem, div, mod, fld, cld, divrem, &, |, xor, ~, !, iszero, isone, isnan, isinf, isfinite, sign, signbit,
        flipsign, copysign, float, round, floor, ceil, trunc, promote_type, Base.promote_rule, sizeof, isempty, haskey,
        in, ncodeunits, codeunit, lastindex, firstindex, eachindex, Base.Order.lt, string, repr, eltype, keytype,
        valtype, nameof, objectid, muladd, fma, widemul, count_ones, leading_zeros, trailing_zeros, ispow2, gcd, lcm,
        Base.SimdLoop.simd_inner_length, Base.SimdLoop.simd_outer_range, Base.SimdLoop.simd_index, Colon(),
        Base.axes1, Base.IteratorSize, Base.IteratorEltype, Base.IndexStyle, Base.mul_with_overflow, Base.add_with_overflow,
        Base.sub_with_overflow, checkbounds, checkindex, nextind, prevind, thisind, isapprox, signed, unsigned,
        Base.has_offset_axes, Base.require_one_based_indexing, isvalid, unsafe_string, Base.mightalias,
    )
    CONTRACTS[f] = PURE
end

for (f, contract) in (
        convert => Contract(; same = 3:3), Base.cconvert => Contract(; same = 3:3),
        Base.unsafe_convert => Contract(; same = 3:3), identity => Contract(; same = 2:2),
        pointer => Contract(; same = 2:2),  # address into object's own storage
        copy => Contract(; overlap = 2:2, fresh = true), Base.unaliascopy => Contract(; overlap = 2:2, fresh = true),
        min => Contract(; same = 2:REST), max => Contract(; same = 2:REST), something => Contract(; same = 2:REST),
        first => Contract(; inside = 2:2), last => Contract(; inside = 2:2), only => Contract(; inside = 2:2),
        getindex => Contract(; inside = 2:2), getproperty => Contract(; inside = 2:2),
        iterate => Contract(; overlap = 2:3), Base.indexed_iterate => Contract(; overlap = 2:2),
        get => Contract(; inside = 2:2, same = 4:4), view => Contract(; contains = 2:2),
        keys => Contract(; contains = 2:2), values => Contract(; contains = 2:2), pairs => Contract(; contains = 2:2),
        adjoint => Contract(; contains = 2:2), transpose => Contract(; contains = 2:2),
        promote => Contract(; contains = 2:REST),
        setindex! => Contract(; writes = [2], stores = [(2, 3:3)], same = 2:2),
        setproperty! => Contract(; writes = [2], stores = [(2, 4:4)], same = 4:4),
        Base.to_indices => Contract(; overlap = 3:3),
        push! => Contract(; writes = [2], stores = [(2, 3:REST)], same = 2:2),
        pushfirst! => Contract(; writes = [2], stores = [(2, 3:REST)], same = 2:2),
        append! => Contract(; writes = [2], shares = [(2, 3:REST)], same = 2:2),
        insert! => Contract(; writes = [2], stores = [(2, 4:4)], same = 2:2),
        fill! => Contract(; writes = [2], stores = [(2, 3:3)], same = 2:2),
        copyto! => Contract(; writes = [2], shares = [(2, 3:REST)], same = 2:2),
        resize! => Contract(; writes = [2], same = 2:2), empty! => Contract(; writes = [2], same = 2:2),
        sizehint! => Contract(; writes = [2], same = 2:2), sort! => Contract(; writes = [2], same = 2:2),
        delete! => Contract(; writes = [2], same = 2:2), pop! => Contract(; writes = [2], inside = 2:2),
        popfirst! => Contract(; writes = [2], inside = 2:2),
        show => Contract(; writes = [2]), print => Contract(; writes = [2]), println => Contract(; writes = [2]),
        write => Contract(; writes = [2], fresh = true), close => Contract(; writes = [2]),
        flush => Contract(; writes = [2]), take! => Contract(; writes = [2], fresh = true),
    )
    CONTRACTS[f] = contract
end

"""Positions of `range` among `nops` operands."""
clip(range::UnitRange{Int}, nops::Int)::UnitRange{Int} = first(range):min(last(range), nops)

"""Summary of call with `nops` operands under `contract`; writes definite, aliases possible."""
function contract_summary(contract::Contract, nops::Int)::Summary
    s = bottom_summary(nops)
    for p in 1:nops
        top = p in contract.writes ? DEFINITE : NONE
        alias(r) = p in clip(r, nops) ? POSSIBLE : NONE
        s.params[p] = ParamEffect(;
            top, inner = top, deep = top, same = alias(contract.same), inside = alias(contract.inside),
            contains = alias(contract.contains), overlap = alias(contract.overlap),
        )
    end
    # container content holds stored operand
    foreach(((j, ks),) -> foreach(k -> j <= nops && push!(s.stores, (j, k, 1, 0)), clip(ks, nops)), contract.stores)
    foreach(((j, ks),) -> foreach(k -> j <= nops && push!(s.stores, (j, k, 1, 1)), clip(ks, nops)), contract.shares)
    return Summary(s.params, s.stores, s.merges, s.globals, s.direct, s.result_globals, false, contract.fresh, true)
end

"""Contract for call of `f` with operand `types` (callee first; `nothing` when unknown), else `nothing`."""
function contract_of(f, types::Union{Nothing, Vector{Any}})::Union{Nothing, Contract}
    (CONTRACTS_ON && f !== nothing) || return nothing
    # non-scalar index into array copies: fresh array sharing elements
    f === getindex && types !== nothing && length(types) >= 3 && types[2] <: AbstractArray &&
        any(t -> t <: Union{AbstractArray, Colon}, types[3:end]) && return Contract(; overlap = 2:2, fresh = true)
    return get(CONTRACTS, f, number_conversion(f) ? PURE : nothing)
end
