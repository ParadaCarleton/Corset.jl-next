"""
`never-succeeds` (F83): call that never returns, without explicit `throw` or `error`; method that never ends.

## Description
Reports call that inference proves never returns: no method matches, field is missing, or callee always throws.
Explicit `throw`, `error` and `rethrow` are exempt. Call of package method reports inside that method, at deepest frame.
Also reports package method that never returns nor throws: loop without exit, or call cycle without base case. Cycle
reports once, at its first method; caller of cycle only inherits it.

## Rationale
Every run of such call throws, so code after it never runs. Cause is often typo in field name, wrong argument order,
or annotation that admits types callee does not accept.

## Example
```julia
struct Point
    x::Float64
end
norm2(point::Point) = point.x^2 + point.y^2
```

## Alternative
```julia
struct Point
    x::Float64
    y::Float64
end
norm2(point::Point) = point.x^2 + point.y^2
```

Cycle that never ends:
```julia
variance(x::Real) = deviation(x)^2
deviation(x::Real) = sqrt(variance(x))
```

## Limitations
Cycle through call that dispatches at run time infers `Any`, so rule does not see it. Neither does loop that inference
cannot prove endless (`while i < n` whose body changes neither).
Rule sees methods inference reaches: annotated methods, and untyped methods that analyzed calls reach.
Finding is `definite` when no argument type method declares lets call return, and call span is exact; else `possible`.
Call that fails for stand-in type only is blind spot. Undefined global name infers `Any`, so rule does not report it.
"""
module NeverSucceeds

using ...Facts

const NAME = Symbol("never-succeeds")

"""Finding for package methods of `cycle` that never return nor throw."""
function endless_finding(cycle::EndlessCycle)::Finding
    why = isempty(cycle.calls) ? "loop never exits, so every call hangs" : "calls recurse without base case, so every call overflows stack"
    return Finding(
        NAME, :never_returns, cycle.confidence, "`$(cycle.name)` never returns", Label(cycle.span, "never returns and never throws"), cycle.calls, why,
        manual_fix(isempty(cycle.calls) ? "add loop exit" : "add base case, or call other method in cycle"),
    )
end

"""Findings for each call inference stage proves never returns, and for each cycle of methods that never end."""
function findings(facts::FactSet)::Vector{Finding}
    inference = facts.inference
    isnothing(inference) && return Finding[]
    calls = map(inference.failing) do failing
        definite = failing.confidence == Confidence.definite
        # Line span cannot show which call of line fails.
        confidence = definite && failing.span.precision == Precision.exact ? Confidence.definite : Confidence.possible
        label = definite ? "throws for every argument type method declares" : "throws for some argument types method declares"
        why = definite ? "every run of this call throws, so code after it never runs" : "call throws for some arguments, so code after it never runs for them"
        return Finding(
            NAME, :never_succeeds, confidence, "call to `$(failing.callee)` never succeeds", Label(failing.span, label),
            [Label(failing.declared, "method declares argument types here")], why,
            manual_fix("fix call, add method for these argument types, or narrow method signature"),
        )
    end
    return [map(endless_finding, inference.endless); calls]
end

const ENTRY = RuleEntry(NAME, Group.correctness, [83], Stage.inference, findings)

end
