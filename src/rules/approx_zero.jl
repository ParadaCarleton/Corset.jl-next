"""
`approx-zero` (F10): approximate compare to zero without `atol` holds only for exact zero.

## Description
Reports `x ≈ 0` and `isapprox(x, 0)` with literal zero and no `atol`.

## Rationale
`isapprox` uses relative tolerance by default. Relative to zero, no nonzero value is close, so test passes only when value is exactly zero.

## Example
```julia
converged = residual(x) ≈ 0
```

## Alternative
```julia
converged = isapprox(residual(x), 0; atol = 1e-8)
```

## Limitations
Rule sees literal zero only. Zero held in variable passes.
"""
module ApproxZero

using ...Facts

const NAME = Symbol("approx-zero")
const PATTERN = IndexedPattern(
    @pattern ~or(
        {x} ≈ 0, 0 ≈ {x}, {x} ≈ 0.0, 0.0 ≈ {x},
        isapprox({x}, 0), isapprox(0, {x}), isapprox({x}, 0.0), isapprox(0.0, {x}),
    )
)

"""Findings for approximate comparisons against literal zero without absolute tolerance."""
function run(facts::FactSet)::Vector{Finding}
    return [
        finding(
            NAME, file, match.node; kind = :literal_zero, confidence = Confidence.definite,
            message = "`$(source(file, match.node))` is true only when `$(source(file, binding(match, :x))) == 0`",
            label = "relative tolerance scales with zero",
            why = "`isapprox` defaults to relative tolerance; relative to zero, no nonzero value is close",
            fix = manual_fix("pass absolute tolerance: `isapprox($(source(file, binding(match, :x))), 0; atol = tol)`"),
        ) for file in facts.files for match in matches(file, PATTERN)
    ]
end

const ENTRY = RuleEntry(NAME, Group.correctness, [10], Stage.syntax, run)

end
