"""
`and-or-precedence` (F106): `&&` on right of `||` binds tighter than reader expects.

## Description
Reports `||` whose right operand starts with `&&` without parentheses: `a || b && c`, `a || b && c || d`.

## Rationale
`&&` binds tighter than `||`, so `a || b && c` is `a || (b && c)`. Read left to right, it looks like `(a || b) && c`.
Guard `done || empty && return` never returns when `done` holds.

## Example
```julia
state === nothing || values === nothing && return nothing
```

## Alternative
```julia
(state === nothing || values === nothing) && return nothing
```

## Limitations
`a && b || c` is `(a && b) || c`, as left-to-right reading gives; rule leaves it alone.
Fix keeps meaning and adds parentheses: `a || (b && c)`. Check that code means it.
"""
module AndOrPrecedence

using ...Facts

const NAME = Symbol("and-or-precedence")
const PATTERN = IndexedPattern(@pattern {left} || {right})

"""
Ungrouped `&&` that starts right operand `node` of `||`: `node` itself, or first operand of ungrouped `||`.
`||` groups to right, so `a || b && c || d` means `a || ((b && c) || d)`, and first operand is never `||`.
"""
function leading_and(file::SyntaxFile, node::SyntaxNode)::Union{Nothing, SyntaxNode}
    first_operand = kind_name(node) == "||" && !haskey(file.groups, node) ? first(children_of(node)) : node
    return kind_name(first_operand) == "&&" && !haskey(file.groups, first_operand) ? first_operand : nothing
end

"""Findings for `||` whose right operand starts with `&&` without grouping parentheses."""
function findings(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, match in matches(file, PATTERN)
        conjunction = leading_and(file, binding(match, :right))
        isnothing(conjunction) && continue
        # Text from spans, so parentheses around whole expression stay out of message.
        whole, inner = span(file, match.node), span(file, conjunction)
        before = file.text[whole.first_byte:prevind(file.text, inner.first_byte)]
        after = file.text[nextind(file.text, inner.last_byte):thisind(file.text, whole.last_byte)]
        operand = source(file, conjunction)
        explicit = "$before($operand)$after"
        push!(
            found, finding(
                NAME, file, match.node; kind = :and_in_or, confidence = Confidence.definite,
                message = "`$before$operand$after` means `$explicit`", label = "parsed as `$explicit`",
                why = "`&&` binds tighter than `||`; read left to right, code looks like `(a || b) && c`",
                fix = replace_fix(file, conjunction, "($operand)", Tier.safe), causes = [Label(inner, "binds first")],
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.readability, [106], Stage.syntax, findings)

end
