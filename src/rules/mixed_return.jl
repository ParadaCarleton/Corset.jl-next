"""
`mixed-return` (F73): explicit `return` mixed with implicit last value.

## Description
Reports long-form function that uses `return` somewhere and ends on plain expression.

## Rationale
Reader must check every path to see what function returns. Explicit final `return` shows result at end.

## Example
```julia
function clamp_positive(x)
    x < 0 && return 0
    x
end
```

## Alternative
```julia
function clamp_positive(x)
    x < 0 && return 0
    return x
end
```

## Limitations
Rule stays narrow: function ending in `if`, loop, `try` or macro call passes. Requiring `return` everywhere would force `return nothing` and fight formatters.
"""
module MixedReturn

using ...Facts

const NAME = Symbol("mixed-return")
"""Final statements whose value is not plain expression; rule stays narrow there."""
const CONTROL = Set(["if", "for", "while", "try", "let", "block", "return", "macrocall", "function", "struct", "module"])

"""`return` nodes of function body `body`, skipping nested functions and closures."""
function own_returns(body)::Vector{Any}
    found = Any[]
    for child in children_of(body)
        kind_name(child) in ("function", "->", "do") && continue
        kind_name(child) == "return" && push!(found, child)
        append!(found, own_returns(child))
    end
    return found
end

"""Findings for long-form functions that return explicitly somewhere and implicitly at end."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, definition in nodes_named(file, "function")
        parts = children_of(definition)
        length(parts) == 2 && kind_name(parts[2]) == "block" || continue
        statements = children_of(parts[2])
        isempty(statements) && continue
        last_statement = statements[end]
        kind_name(last_statement) in CONTROL && continue
        returns = own_returns(parts[2])
        isempty(returns) && continue
        push!(
            found, finding(
                NAME, file, last_statement; kind = :implicit_tail, confidence = Confidence.definite,
                message = "function mixes `return` with implicit last value", label = "implicit return",
                why = "reader must check every path to see what function returns",
                fix = replace_fix(file, last_statement, "return " * source(file, last_statement), Tier.safe),
                causes = [Label(span(file, returns[1]), "explicit return")],
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.readability, [73], Stage.syntax, run)

end
