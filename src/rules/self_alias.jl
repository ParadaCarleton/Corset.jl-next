"""
`self-alias` (F50): `!` call writes operand while it reads same memory through other operand.

## Description
Reports `!` call whose written operand also reaches call as other operand. Same object passed to function that breaks
on it (`sum!`, `prod!`, `any!`, `all!`, `count!`, `splice!`, `circshift!`, `circcopy!`, `mul!`, `transpose!`,
`adjoint!`) is `definite`. Overlapping view (`view(x, 2:n)` with `view(x, 1:n-1)`) passed to function whose docstring
carries Base aliasing warning is `possible`.

## Rationale
Base docstrings warn: "Behavior can be unexpected when any mutated argument shares memory with any other argument."
`sum!(x, x)` fills `x` with zero before it reads `x`, so result is zero. `map!` over overlapping views reads elements
it already wrote.

## Example
```julia
function shift_right!(values::AbstractVector{Float64})
    map!(identity, view(values, 2:lastindex(values)), view(values, 1:(lastindex(values) - 1)))
    return values
end
```

## Alternative
```julia
function shift_right!(values::AbstractVector{Float64})
    values[2:end] = values[1:(end - 1)]
    return values
end
```

## Limitations
Same object passed to other warned function gives no finding: Base docstring calls `map!(f, A, A)` equivalent of
`map!(f, A)`. Functions that unalias operands (`copyto!`, `copy!`, `setindex!`, `prepend!`, `broadcast!`) give none.
Views of one array that never overlap still give `possible`: overlap depends on index values. Fix is `manual`.
"""
module SelfAlias

using ...Facts

const NAME = Symbol("self-alias")

"""Findings for each `!` call that reads memory it writes through other operand."""
function findings(facts::FactSet)::Vector{Finding}
    effects = facts.effects
    isnothing(effects) && return Finding[]
    return [
        Finding(
            NAME, :self_alias, call.confidence, "`$(call.callee)` writes memory it also reads through other operand",
            Label(call.call, "passes one array as output and input"), Label[],
            "function can read elements it already overwrote, so result is wrong",
            manual_fix("pass copy of read operand (`copy(x)`), or write into other array"),
        ) for method in effects.methods for call in method.self_aliases
    ]
end

const ENTRY = RuleEntry(NAME, Group.correctness, [50], Stage.effects, findings)

end
