"""`untyped-empty` (F21): `[]` and `Dict()` have `Any` element type."""
module UntypedEmpty

using ...Facts

const NAME = Symbol("untyped-empty")
const PATTERN = IndexedPattern(@pattern ~or([], Dict(), Set(), IdDict(), Vector(), Vector(undef, {_})))

"""Findings for empty containers with `Any` element type."""
function run(facts::FactSet)::Vector{Finding}
    return [
        finding(
            NAME, file, match.node; kind = :any_element, confidence = Confidence.definite,
            message = "`$(source(file, match.node))` has element type `Any`",
            label = "holds `Any`", why = "every element read dispatches at run time and boxes values",
            fix = manual_fix("name element type: `Float64[]`, `Dict{String, Int}()`; write `Any[]` when `Any` is intended"),
        ) for file in facts.files for match in matches(file, PATTERN)
    ]
end

const ENTRY = RuleEntry(NAME, Group.performance, [21], Stage.syntax, run)

end
