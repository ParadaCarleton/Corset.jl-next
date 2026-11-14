"""
`method-ambiguity` (F94): two package methods match same call, and neither is more specific.

## Description
Reports each pair of package methods `Test.detect_ambiguities` finds, as Aqua.jl does.
Finding sits on later definition; cause label marks earlier one. Message names call that matches both.

## Rationale
Call that matches both methods throws `MethodError`, even when no test makes that call.
Check covers argument combinations no analyzed caller reaches.

## Example
```julia
combine(left::Int, right) = left
combine(left, right::Int) = right
```

## Alternative
```julia
combine(left::Int, right) = left
combine(left, right::Int) = right
combine(left::Int, right::Int) = left + right
```

## Limitations
Pair with method of other package passes: package alone cannot pick winner.
Rule sees definitions in analyzed files of loaded package only. Keyword methods report through their positional methods.
"""
module MethodAmbiguity

using ...Facts

const NAME = Symbol("method-ambiguity")

"""Findings for each ambiguous pair of package methods, at later definition."""
function findings(facts::FactSet)::Vector{Finding}
    external = facts.external
    isnothing(external) && return Finding[]
    return map(external.ambiguities) do (earlier, later)
        call = call_text(later.method.name, typeintersect(earlier.method.sig, later.method.sig))
        return Finding(
            NAME, :method_ambiguity, Confidence.definite, "`$call` matches two methods; neither is more specific",
            Label(name_span(later), "ambiguous with earlier method"), [Label(name_span(earlier), "also matches `$call`")],
            "call that matches both methods throws `MethodError`", manual_fix("define `$call`, or narrow one signature"),
        )
    end
end

const ENTRY = RuleEntry(NAME, Group.correctness, [94], Stage.external, findings)

end
