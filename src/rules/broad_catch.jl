"""
`broad-catch` (F59): `catch` handles every error.

## Description
Reports `catch` block that neither tests error type nor passes error on.

## Rationale
Bare `catch` also catches `InterruptException`, `OutOfMemoryError` and bugs such as `MethodError`, then hides them.

## Example
```julia
value = try
    parse(Int, text)
catch
    0
end
```

## Alternative
```julia
value = try
    parse(Int, text)
catch error
    error isa ArgumentError || rethrow()
    0
end
```

## Limitations
Rule accepts `isa` test on caught variable, `rethrow`, `throw` and `error` as narrowing. It does not check that test names right type.
"""
module BroadCatch

using ...Facts

const NAME = Symbol("broad-catch")
"""Calls that pass error on."""
const PASSING = Set(["rethrow", "throw", "error"])

"""Whether handler `block` passes error on, or tests type of caught variable `variable` (`nothing`: no variable)."""
function narrows(block::SyntaxNode, variable::Union{Nothing, String})::Bool
    return any(descendants(block)) do node
        call_head(node) in PASSING ||
            (call_head(node) == "isa" && !isnothing(variable) && identifier_name(children_of(node)[1]) == variable)
    end
end

"""Findings for catch clauses that swallow every error, `InterruptException` included."""
function findings(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, clause in forms(file, "catch")
        parts = children_of(clause)
        narrows(parts[end], identifier_name(parts[1])) && continue
        push!(
            found, finding(
                NAME, file, clause; kind = :untyped_catch, confidence = Confidence.definite,
                message = "`catch` handles every error", label = "no type test, no rethrow",
                why = "typos, `MethodError` and `InterruptException` vanish with intended errors",
                fix = manual_fix("handle expected type only: `e isa MyError || rethrow()`"),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.safety, [59], Stage.syntax, findings)

end
