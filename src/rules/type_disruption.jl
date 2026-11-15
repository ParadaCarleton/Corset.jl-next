"""
`type-disruption` (F5, F6, F16): literal, constant or type name changes type of input that method returns or stores.

## Description
Reports weak value that meets generic number input and changes type of value method returns or stores in argument or
global. Weak value: number literal, constant, call of weak values only (`sqrt(2)`, `2π`), variable assigned one, or
conversion to Base number type (`Float64(x)`). Integer weak value must keep integer and float input type; float weak
value must keep float input type, as Python scalars do in NumPy 2.

## Rationale
Generic method should give back caller's number type. `x * 0.5` turns `Float32` into `Float64`, which doubles memory and
leaves GPU fast path; `2x` turns `Int32` into `Int64`. Float literal close to `π` or `sqrt(2)` widens too, where
irrational constant would take input type.

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
```

## Limitations
Rule sees methods inference reaches, with stand-in types for generic arguments. Value used only as index is exempt:
`xs[2i]` converts index to `Int`. Store into concrete element or field type converts value; `intermediate-widening`
reports work in wider type there. Base callees count as type-preserving. Finding is `possible` when method branches on
type or span cannot show weak value. Rule does not report hard-coded `Array` construction (F16) yet.
"""
module TypeDisruption

using ...Facts

const NAME = Symbol("type-disruption")

"""Findings for each weak value that changes type of returned or stored value."""
function findings(facts::FactSet)::Vector{Finding}
    inference = facts.inference
    isnothing(inference) && return Finding[]
    found = Finding[]
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
