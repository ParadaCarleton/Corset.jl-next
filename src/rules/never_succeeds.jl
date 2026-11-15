"""
`never-succeeds` (F83): call that never returns, without explicit `throw` or `error`.

## Description
Reports call that inference proves never returns: no method matches, field is missing, or callee always throws.
Explicit `throw`, `error` and `rethrow` are exempt. Call of package method reports inside that method, at deepest frame.

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

## Limitations
Rule sees methods inference reaches: annotated methods, and untyped methods that analyzed calls reach.
Finding is `definite` when no argument type method declares lets call return, and call span is exact; else `possible`.
Call that fails for stand-in type only is blind spot. Undefined global name infers `Any`, so rule does not report it.
"""
module NeverSucceeds

using ...Facts

const NAME = Symbol("never-succeeds")

"""Findings for each call inference stage proves never returns."""
function findings(facts::FactSet)::Vector{Finding}
    inference = facts.inference
    isnothing(inference) && return Finding[]
    return map(inference.failing) do failing
        span = failing.code.spans[failing.statement]
        definite = failing.confidence == Confidence.definite
        # Line span cannot show which call of line fails.
        confidence = definite && span.precision == Precision.exact ? Confidence.definite : Confidence.possible
        label = definite ? "throws for every argument type method declares" : "throws for some argument types method declares"
        why = definite ? "every run of this call throws, so code after it never runs" : "call throws for some arguments, so code after it never runs for them"
        return Finding(
            NAME, :never_succeeds, confidence, "call to `$(failing.callee)` never succeeds", Label(span, label),
            [Label(name_span(failing.code.site), "method declares argument types here")], why,
            manual_fix("fix call, add method for these argument types, or narrow method signature"),
        )
    end
end

const ENTRY = RuleEntry(NAME, Group.correctness, [83], Stage.inference, findings)

end
