"""
`annotation` (F71): argument or result without type.

## Description
Reports named function definition with untyped argument or no result type, once per method.
Cause labels mark each untyped argument and missing result type.

## Rationale
Signature is first thing reader sees. Types there say what function accepts and returns without reading body.
Result annotation also acts as check: `result-conversion` reports annotation that converts.

## Example
```julia
area(width, height) = width * height
```

## Alternative
```julia
area(width::Real, height::Real)::Real = width * height
```

## Limitations
Exempt: `_` and unnamed `::T` arguments, keyword splat (Julia rejects its type), anonymous functions, and local
functions (closures).
Abstract types are intended. `::Any` accepts anything on purpose and opts out.
"""
module Annotation

using ...Facts

const NAME = :annotation

"""Untyped names bound by argument `node`, through default value, splat and keyword group; `_` binds nothing."""
function untyped(node::SyntaxNode)::Vector{SyntaxNode}
    kind = kind_name(node)
    # Keyword splat cannot carry type: `f(; options::Any...)` is syntax error.
    kind == "parameters" && return reduce(vcat, (untyped(child) for child in children_of(node) if kind_name(child) != "..."); init = SyntaxNode[])
    kind in ("=", "kw", "...") && return untyped(children_of(node)[1])
    kind == "Identifier" && return identifier_name(node) == "_" ? SyntaxNode[] : [node]
    return kind == "tuple" ? [node] : SyntaxNode[]
end

"""Whether `definition` sits inside function body, so it is closure."""
is_local(definition::SyntaxNode)::Bool = any(ancestor -> kind_name(ancestor) in ("function", "->", "do"), ancestors(definition))

"""Findings for named methods with untyped arguments or no result type."""
function findings(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, definition in forms(file, "function")
        parts = signature(definition)
        (isnothing(parts) || is_local(definition)) && continue
        causes = [Label(span(file, argument), "no type") for parameter in parts.arguments for argument in untyped(parameter)]
        parts.typed || push!(causes, Label(span(file, parts.call), "no result type"))
        isempty(causes) && continue
        name = definition_name(definition)
        push!(
            found, finding(
                NAME, file, name; kind = :missing_type, confidence = Confidence.definite, causes,
                message = "`$(source(file, name))` signature lacks types", label = "method defined here",
                why = "reader must read body to learn what function accepts and returns",
                fix = manual_fix("annotate with intended abstract types; `::Any` accepts anything on purpose"),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.readability, [71], Stage.syntax, findings)

end
