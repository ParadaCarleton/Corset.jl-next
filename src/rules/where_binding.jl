"""
`where-binding` (F4): `where` after result annotation binds result type.

## Description
Reports short-form method `f(x::T)::T where {T} = …` whose `where` clause attaches to result annotation.

## Rationale
Parser reads `f(x::T)::T where {T}` as `f(x::T)::(T where {T})`. Signature then names free `T`: definition errors, or silently uses global `T` when one exists.

## Example
```julia
same(x::T)::T where {T} = x
```

## Alternative
```julia
(same(x::T)::T) where {T} = x
```

## Limitations
None known. Upstream kept this precedence (JuliaLang/julia#21847).
"""
module WhereBinding

using ...Facts

const NAME = Symbol("where-binding")
const PATTERN = IndexedPattern(@pattern {signature}::{annotation})

"""Whether `node` is signature of short-form method definition `signature = body`."""
function defines_method(node::SyntaxNode)::Bool
    parent = parent_of(node)
    return !isnothing(parent) && kind_name(parent) == "function" && children_of(parent)[1] === node
end

"""Findings for short-form definitions whose `where` clause attaches to result annotation."""
function findings(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, match in matches(file, PATTERN)
        annotated = children_of(match.node)
        clause = annotated[2]
        kind_name(clause) == "where" && defines_method(match.node) || continue
        result, parameters = children_of(clause)[1], children_of(clause)[2:end]
        replacement = "(" * source(file, annotated[1]) * "::" * source(file, result) * ") where " *
            join((source(file, parameter) for parameter in parameters), " ")
        push!(
            found, finding(
                NAME, file, match.node; kind = :result_where, confidence = Confidence.definite,
                message = "`where` binds result type `$(source(file, result))`, not method",
                label = "`where` attaches to result annotation", why = "method gets no type parameter: call errors, or uses global of same name",
                fix = replace_fix(file, match.node, replacement, Tier.safe),
                causes = [Label(span(file, clause), "parsed as `$(source(file, result)) where …`")],
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [4], Stage.syntax, findings)

end
