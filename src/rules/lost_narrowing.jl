"""
`lost-narrowing` (F107): type test in `&&` or `||` chain narrows variable inside chain only.

## Description
Reports type test (`x isa T`, `x !== nothing`, `!isnothing(x)`) in `&&` or `||` chain whose value guards code, when
code after guard reads variable as wider type. Guards: `(a && b) || return`, `(a || b) && continue`,
`if !(a && b) return end`.

## Rationale
Lowering stores chain value before guard branches on it. Inference narrows variable on branch of type test only, so
after guard, `x` is `Any` again. Each read dispatches at run time, and method that loads later can invalidate code.

## Example
```julia
function head_args(x)
    (x isa Expr && x.head === :call) || return nothing
    return x.args
end
```

## Alternative
```julia
function head_args(x)
    x isa Expr || return nothing
    x.head === :call || return nothing
    return x.args
end
```

## Limitations
Rule sees methods inference reaches, and reports where typed code proves loss: test is not constant, and read after
guard has wider type. Lowering branches directly on `||` chain and `if a && b`, so they keep narrowing; condition stored
in variable (`ok = a || b`) loses it. Fix splits guard, one guard per term, when guard is own statement, its value goes
unused, its exit leaves block (`return`, `continue`, `break`, `throw`, `error`, `rethrow`), and no comment sits inside;
else fix is `manual`.
"""
module LostNarrowing

using ...Facts

const NAME = Symbol("lost-narrowing")

"""Findings for each type test whose narrowing guard chain drops."""
function findings(facts::FactSet)::Vector{Finding}
    inference = facts.inference
    isnothing(inference) && return Finding[]
    return map(inference.narrowings) do lost
        fix = isnothing(lost.split) ? manual_fix("move type test of `$(lost.variable)` to guard of its own, before chain") :
            Fix("split guard, one guard per term", [Edit(lost.guard, lost.split)], Tier.safe)
        return Finding(
            NAME, :lost_narrowing, Confidence.definite, "`$(lost.chain)` chain drops narrowing of `$(lost.variable)` to `$(lost.narrowed)`",
            Label(lost.test, "narrows `$(lost.variable)` inside chain only"), [Label(lost.read, "reads `$(lost.variable)` as `$(lost.found)`")],
            "lowering stores chain value before guard branches, so code after guard reads `$(lost.variable)` as `$(lost.found)` and dispatches at run time",
            fix,
        )
    end
end

const ENTRY = RuleEntry(NAME, Group.performance, [107], Stage.inference, findings)

end
