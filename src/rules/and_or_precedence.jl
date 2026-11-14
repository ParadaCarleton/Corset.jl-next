"""
`and-or-precedence` (F106): `&&` on right of `||` binds tighter than reader expects.

## Description
Reports `||` whose right operand is `&&` without parentheses: `a || b && c`.

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

"""Findings for `||` whose right operand is `&&` without grouping parentheses."""
function findings(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, match in matches(file, PATTERN)
        right = binding(match, :right)
        kind_name(right) == "&&" && !haskey(file.groups, right) || continue
        # Operand text, so parentheses around whole expression stay out of message.
        left = source(file, binding(match, :left))
        explicit = "$left || ($(source(file, right)))"
        push!(
            found, finding(
                NAME, file, match.node; kind = :and_in_or, confidence = Confidence.definite,
                message = "`$left || $(source(file, right))` means `$explicit`", label = "parsed as `$explicit`",
                why = "`&&` binds tighter than `||`; read left to right, code looks like `(a || b) && c`",
                fix = replace_fix(file, match.node, explicit, Tier.safe), causes = [Label(span(file, right), "binds first")],
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.readability, [106], Stage.syntax, findings)

end
