"""`approx-zero` (F10): `x ≈ 0` uses relative tolerance only, so it holds only when `x == 0`."""
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

const ENTRY = RuleEntry(NAME, Group.correctness, [10], Family.A, run)

end
