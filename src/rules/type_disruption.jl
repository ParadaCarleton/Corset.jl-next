"""
`type-disruption` (F5, F6, F16): literal, constant, type name or hard-coded `Array` changes type of input that method
returns or stores.

## Description
Reports weak value that meets generic float input and changes type of value method returns or stores in argument or
global. Weak value: number literal, constant, call of weak values only (`sqrt(2)`, `2π`), variable assigned one, or
conversion to wider Base float type (`Float64(x)`). Weak value must keep float input type, as Python scalars do in
NumPy 2.
Also reports hard-coded `Array` (`zeros(n)`, `Vector{T}(undef, n)`) in method with input array, when method returns or
stores it, or mixes it with input array (`possible`).

## Rationale
Generic method should give back caller's number type. `x * 0.5` turns `Float32` into `Float64`, which doubles memory and
leaves GPU fast path. Float literal close to `π` or `sqrt(2)` widens too, where irrational constant would take input
type. Array built with `similar` of input keeps GPU, static and offset array types; hard-coded `Array` drops them.

## Example
```julia
scaled(x::AbstractFloat) = x * 0.5
function total(xs::AbstractVector{<:Real})
    s = 0
    for x in xs
        s += x
    end
    return s
end
halves(xs::AbstractVector) = fill(0.5, length(xs))
```

## Alternative
```julia
scaled(x::AbstractFloat) = x * oftype(x, 0.5)
function total(xs::AbstractVector{<:Real})
    s = zero(eltype(xs))
    for x in xs
        s += x
    end
    return s
end
halves(xs::AbstractVector) = fill!(similar(xs, Float64, length(xs)), 0.5)
```

## Limitations
Rule sees methods inference reaches, with stand-in types for generic arguments. Integer input is exempt: Julia promotes
small integers to `Int` on purpose (`sum(Int32[1])`, index math). Store into concrete element, dictionary value or field
type converts value; `intermediate-widening` reports work in wider type there. Base callees count as type-preserving.
Finding is `possible` when method branches on type or span cannot show weak value. Hard-coded `Array` gets no finding
in method without input array, and none for `rand`, `collect` or array literal.
Fix converts float weak value to input type: `T(0.5)`, `oftype(x, 0.5)` or `eltype(xs)(0.5)`. `float` wraps type when
declaration admits integers, since `oftype(1, 0.5)` throws. Fix tier is `likely`: callers see input type. Fix stays
`manual` for irrational value, start value, conversion, product `2.0x`, reassigned argument, and code inside macro
other than `@inline`, `@inbounds` and similar.
Fix builds hard-coded array from input: `zeros(n)` gives `fill!(similar(xs, Float64, n), 0.0)`, `Vector{T}(undef, n)`
gives `similar(xs, T, n)`. It stays `manual` for computed `fill` value, type without parameter and no dimensions.
"""
module TypeDisruption

using ...Facts

const NAME = Symbol("type-disruption")

"""Labels of `array`: construction builds it, then exit returns, stores or mixes it; one label when spans coincide."""
function array_labels(array::HardArray)::Tuple{Label, Vector{Label}}
    built = "builds `$(array.array)` for every input array type"
    exit = array.exit == Exit.returned ? "returns it" : array.exit == Exit.stored ? "stores it" : "mixes it with `$(array.template)`"
    array.exit_span == array.span && return Label(array.span, "$built and $exit"), Label[]
    return Label(array.span, built), [Label(array.exit_span, "$exit here")]
end

"""Fix of `array`: build it from template (`likely`: callers see template's array type), else `manual`."""
function array_fix(array::HardArray)::Fix
    rebuilt = array.rebuilt
    isnothing(rebuilt) && return manual_fix("build it with `similar($(array.template), T, dims)`, so it keeps caller's array type")
    return Fix("build from `$(array.template)`: `$rebuilt`", [Edit(array.span, rebuilt)], Tier.likely)
end

"""Findings for each weak value that changes type of returned or stored value, and each hard-coded array."""
function findings(facts::FactSet)::Vector{Finding}
    inference = facts.inference
    isnothing(inference) && return Finding[]
    found = Finding[]
    for array in inference.hard_arrays
        primary, causes = array_labels(array)
        push!(
            found, Finding(
                NAME, :hard_array, array.confidence, "hard-coded `$(array.array)` drops array type of `$(array.template)`", primary, causes,
                "GPU, static and offset arrays turn into CPU `Array`, or fail when mixed with it", array_fix(array),
            )
        )
    end
    for disruption in inference.disruptions
        disruption.exit == Exit.intermediate && continue
        verb = disruption.exit == Exit.returned ? "returns" : "stores"
        exit_text = "$verb `$(disruption.found)` instead of `$(disruption.expected)`"
        push!(
            found, Finding(
                NAME, :type_disruption, disruption.confidence, "$(weak_words(disruption)) turns `$(disruption.input)` input into `$(disruption.found)`",
                Label(disruption.span, weak_label(disruption)), weak_causes(disruption, exit_text),
                "result takes weak value's type, so callers lose their number type", weak_fix(disruption),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.composability, [5, 6, 16], Stage.inference, findings)

end
