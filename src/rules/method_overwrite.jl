"""
`method-overwrite` (F24): later method definition replaces earlier one with same positional signature.

## Description
Reports method definition that replaces earlier definition of same function with same positional argument types.

## Rationale
Keywords take no part in dispatch, so `f(x; a)` and `f(x; b)` define one method twice. Positional calls reach only later body.
When later definition has no keywords, keyword calls still reach earlier body: one function runs two bodies.
Julia refuses to precompile package with overwrite, so every `using` loads package from source.

## Example
```julia
area(side; scale = 1) = scale * side^2
area(side; units = :m) = side^2
```

## Alternative
```julia
area(side; scale = 1, units = :m) = scale * side^2
```

## Limitations
Rule sees definitions in analyzed files of loaded package only.
"""
module MethodOverwrite

using ...Facts

const NAME = Symbol("method-overwrite")

"""Findings for each method definition that replaced earlier definition with same signature, at later definition."""
function findings(facts::FactSet)::Vector{Finding}
    package = facts.package
    isnothing(package) && return Finding[]
    return map(package.overwrites) do (earlier, later)
        signature = call_text(later.method.name, later.method.sig)
        return Finding(
            NAME, :method_overwrite, Confidence.definite, "`$signature` defined twice; later definition replaces earlier one",
            Label(name_span(later), "replaces earlier method"), [Label(name_span(earlier), "positional calls never reach this body")],
            "keywords take no part in dispatch, and package with overwrite cannot precompile",
            manual_fix("merge bodies into one method, or give methods different argument types"),
        )
    end
end

const ENTRY = RuleEntry(NAME, Group.correctness, [24], Stage.package, findings)

end
