"""
`one-based-range` (F36): index into array whose axes can start anywhere has no proof that it comes from those axes.

## Description
Reports index into array argument with no proof that it lies in axes of that array. Proof: index comes from
`eachindex(x)`, `axes(x)`, `keys(x)`, `pairs(x)`, `firstindex(x)`, `lastindex(x)`, `begin`, `end`, `LinearIndices(x)`,
`CartesianIndices(x)` or search result (`findfirst`, `argmax`, `sortperm`, …) on `x`, or is `i ± k`, `prevind`,
`nextind`, `min`, `max`, `clamp` or midpoint of such indices. `similar(x)`, `copy(x)` and broadcast of `x` with scalars
share axes of `x`. Guard `Base.require_one_based_indexing(x)`, or `axes(x) == axes(y)` that throws otherwise, proves
indices after it. Literal, `length`, `size` or `enumerate` counter, or index of other array, gives `definite`; index of
unknown source gives `possible`.

Index argument passes in its method: method takes contract that callers pass index of that array. Rule checks each
package call against contracts of methods it can run, with same proof. Method that passes its own index and array
arguments on takes contract too.

## Rationale
Array type with offset axes (`OffsetArray`) starts its indices elsewhere than 1. Index `1` or loop over
`1:length(x)` then reads wrong element or throws. Tests with `Vector` do not show this.

## Example
```julia
function total(xs::AbstractVector{Float64})
    s = 0.0
    for i in 1:length(xs)
        s += xs[i]
    end
    return s
end
```

## Alternative
```julia
function total(xs::AbstractVector{Float64})
    s = 0.0
    for i in eachindex(xs)
        s += xs[i]
    end
    return s
end
```

## Limitations
Rule checks array arguments that inference sees as array stand-ins: it infers each such method again with
`OffsetArray` arguments. Contract names arguments only: index in field or tuple, arithmetic of several index
arguments (`x[i + delta]`), and call with keyword arguments or splat, check nothing. Stored index passes nowhere: copy input to `Vector` or guard it. `checkbounds` gives no proof.
Rule sees methods inference reaches. Fix is `manual`.
"""
module OneBasedRange

using ...Facts

const NAME = Symbol("one-based-range")

const REASON = "array with offset axes starts its indices elsewhere than 1, so this index can read wrong element"

const FIX = "take index from `eachindex`, `axes`, `firstindex` or `begin`, or guard with `Base.require_one_based_indexing`"

"""Findings for each index without proof into array whose axes can start anywhere, in method or passed to call."""
function findings(facts::FactSet)::Vector{Finding}
    effects = facts.effects
    isnothing(effects) && return Finding[]
    found = Finding[]
    for method in effects.methods, unproven in method.indices.unproven
        array = isnothing(unproven.array) ? "array" : "`$(unproven.array)`"
        causes = isnothing(unproven.source) ? Label[] : [Label(something(unproven.source), "index comes from here")]
        message = "index into $array has no proof that it comes from its axes"
        push!(found, Finding(NAME, :unproven, unproven.confidence, message, Label(unproven.site, "index without proof"), causes, REASON, manual_fix(FIX)))
    end
    return append!(found, call_findings(effects.methods))
end

"""Findings for each package call that passes index without proof that it comes from array it indexes in callee."""
function call_findings(methods::AbstractVector{MethodEffects})::Vector{Finding}
    contracts, found, seen = method_contracts(methods), Finding[], Set{Tuple{Span, Int, Int}}()
    for method in methods, call in method.indices.calls, callee in call.callees, contract in get(contracts, callee, IndexContract[])
        confidence, key = broken(call, contract), (call.site, contract.index, contract.array)
        (isnothing(confidence) || key in seen) && continue
        push!(seen, key)
        message = "argument $(contract.index) of call has no proof that it comes from axes of argument $(contract.array)"
        causes = [Label(contract.site, "it indexes array here")]
        push!(found, Finding(NAME, :unproven, something(confidence), message, Label(call.site, "index without proof"), causes, REASON, manual_fix(FIX)))
    end
    return found
end

"""
Index contracts of each package method signature, in order found: its own, and those it takes by passing its index
and array arguments on to call whose method has contract.
"""
function method_contracts(methods::AbstractVector{MethodEffects})::Dict{Type, Vector{IndexContract}}
    contracts = Dict{Type, Vector{IndexContract}}()
    for method in methods
        own = get!(Vector{IndexContract}, contracts, method.site.method.sig)
        for contract in method.indices.contracts
            contract in own || push!(own, contract)
        end
    end
    # Each round adds contracts one call deeper; contracts are finite, so rounds end.
    added = true
    while added
        added = add_inherited!(contracts, methods)
    end
    return contracts
end

"""Add to `contracts` those each method of `methods` takes through its calls; whether any is new."""
function add_inherited!(contracts::AbstractDict{<:Type, <:AbstractVector{IndexContract}}, methods::AbstractVector{MethodEffects})::Bool
    added = false
    for method in methods, call in method.indices.calls, callee in call.callees
        own = contracts[method.site.method.sig]
        # Copy: recursive call takes contracts of its own method.
        for contract in copy(get(contracts, callee, IndexContract[])), taken in inherited(call, contract)
            taken in own && continue
            push!(own, taken)
            added = true
        end
    end
    return added
end

"""Contracts of caller that `call` passes `contract` of its callee to: index and array are both caller arguments."""
function inherited(call::IndexCall, contract::IndexContract)::Vector{IndexContract}
    array = call_array(call, contract)
    isnothing(array) && return IndexContract[]
    parameter = array.parameter
    parameter == 0 && return IndexContract[]
    return [
        IndexContract(claim.target, contract.element, parameter, contract.position, contract.count, contract.site)
            for claim in index_claims(call, contract) if claim.source == IndexSource.parameter && claim.target > 0
    ]
end

"""
Certainty that `call` breaks `contract` of its callee: none when array has no offset axes there, or index comes from
that array or caller argument; else `definite` for index with known source, `possible` for unknown source.
"""
function broken(call::IndexCall, contract::IndexContract)::Union{Nothing, Confidence.T}
    array = call_array(call, contract)
    isnothing(array) && return nothing
    dimensions, claims = array.dimensions, index_claims(call, contract)
    any(claim -> claim.source == IndexSource.parameter || proves(claim, contract, dimensions), claims) && return nothing
    return isempty(claims) ? Confidence.possible : Confidence.definite
end

"""Whether `claim` is index of array argument of `contract` in dimension its position addresses, with array `dimensions`."""
function proves(claim::OperandIndex, contract::IndexContract, dimensions::Union{Nothing, Integer})::Bool
    claim.source == IndexSource.array || return false
    claim.target == contract.array || return false
    return contract.count == 1 ? claim.dimension == 0 || (claim.dimension == 1 && dimensions == 1) : claim.dimension == contract.position
end

"""Array operand of `call` that `contract` names, when its axes can start anywhere there."""
function call_array(call::IndexCall, contract::IndexContract)::Union{Nothing, ArrayOperand}
    position = findfirst(array -> array.operand == contract.array, call.arrays)
    return isnothing(position) ? nothing : call.arrays[position]
end

"""Index claims of operand of `call` that `contract` names as index, of same kind (index or collection of indices)."""
index_claims(call::IndexCall, contract::IndexContract)::Vector{OperandIndex} = [claim for claim in call.claims if claim.operand == contract.index && claim.element == contract.element]

const ENTRY = RuleEntry(NAME, Group.composability, [36], Stage.effects, findings)

end
