"""
`intermediate-widening` (F87): literal or constant makes intermediate run in wider type than input.

## Description
Reports weak value that meets generic float input and widens intermediate value, while returned and stored values keep
their type: conversion or concrete store narrows result again. Weak values as in `type-disruption`, which reports
widening that escapes.

## Rationale
`Float32(x * 0.5)` computes product in `Float64`, then rounds back. Work in wider type is slow on GPU and halves SIMD
width.

## Example
```julia
half32(x::AbstractFloat) = Float32(x * 0.5)
```

## Alternative
```julia
half32(x::AbstractFloat) = Float32(x * oftype(x, 0.5))
```

## Limitations
Fix changes rounding of intermediate, so it can change result in last bit. Integer input is exempt, as in
`type-disruption`. Finding is `possible` when method branches on type or span cannot show weak value.
"""
module IntermediateWidening

using ...Facts

const NAME = Symbol("intermediate-widening")

"""Findings for each weak value that widens intermediate only."""
function findings(facts::FactSet)::Vector{Finding}
    inference = facts.inference
    isnothing(inference) && return Finding[]
    found = Finding[]
    for disruption in inference.disruptions
        disruption.exit == Exit.intermediate || continue
        exit_text = "computes `$(disruption.found)` instead of `$(disruption.expected)`"
        push!(
            found, Finding(
                NAME, :intermediate_widening, disruption.confidence, "$(weak_words(disruption)) makes `$(disruption.input)` input compute in `$(disruption.found)`",
                Label(disruption.span, weak_label(disruption)), weak_causes(disruption, exit_text),
                "intermediate runs in wider type, though result keeps input type", weak_fix(disruption),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.performance, [87], Stage.inference, findings)

end
