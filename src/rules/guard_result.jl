"""
`guard-result` (F114): function result is value of `&&` or `||` guard.

## Description
Reports guard as last value of named function, long form or short form. Guard: chain whose last term exits.
`||` guard gives `true` when it passes; `&&` guard gives `false`.

## Rationale
Reader cannot tell whether `Bool` result is API. Caller may come to depend on constant nobody chose.

## Example
```julia
check(x) = x > 0 || throw(DomainError(x))
```

## Alternative
```julia
function check(x)
    x > 0 || throw(DomainError(x))
    return nothing
end
```

## Limitations
Closure and `do` block pass, since caller picks use of value.
Ternary with exit branch gives value of other branch and passes.
Fix is manual: add `nothing` after guard when callers ignore result, or `return true` when they use it.
"""
module GuardResult

using ...Facts

const NAME = Symbol("guard-result")

"""Findings for guards whose value is result of named function."""
function findings(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, operator in ("&&", "||"), node in forms(file, operator)
        exit_guard(node) && !later_term(node) || continue
        owner = returning_function(node)
        isnothing(owner) && continue
        value = operator == "||" ? "true" : "false"
        push!(
            found, finding(
                NAME, file, node; kind = :guard_value, confidence = Confidence.definite,
                message = "function returns `$value` when guard passes", label = "guard value is function result",
                why = "reader cannot tell whether `Bool` result is API",
                fix = manual_fix("add `nothing` after guard when callers ignore result; `return $value` when they use it"),
                causes = [Label(span(file, definition_name(owner)), "function")],
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.readability, [114], Stage.syntax, findings)

end
