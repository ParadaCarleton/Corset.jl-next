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
`OffsetArray` arguments. Index argument (`f(x, i) = x[i]`) passes: caller proves it. Call sites do not check that
contract yet: `f(x, 1)` passes. Stored index passes nowhere: copy
input to `Vector` or guard it. `checkbounds` gives no proof. Rule sees methods inference reaches. Fix is `manual`.
"""
module OneBasedRange

using ...Facts

const NAME = Symbol("one-based-range")

"""Findings for each index without proof into array whose axes can start anywhere."""
function findings(facts::FactSet)::Vector{Finding}
    effects = facts.effects
    isnothing(effects) && return Finding[]
    found = Finding[]
    for method in effects.methods, unproven in method.unproven_indices
        array = isnothing(unproven.array) ? "array" : "`$(unproven.array)`"
        causes = isnothing(unproven.source) ? Label[] : [Label(something(unproven.source), "index comes from here")]
        push!(
            found, Finding(
                NAME, :unproven, unproven.confidence, "index into $array has no proof that it comes from its axes",
                Label(unproven.site, "index without proof"), causes,
                "array with offset axes starts its indices elsewhere than 1, so this index can read wrong element",
                manual_fix("take index from `eachindex`, `axes`, `firstindex` or `begin`, or guard with `Base.require_one_based_indexing`"),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [36], Stage.effects, findings)

end
