"""
`juxtaposition` (F3): juxtaposition binds tighter than reader expects.

## Description
Reports division or power whose right operand is juxtaposed product without parentheses: `1/2x`, `2^2x`.

## Rationale
Juxtaposition binds tighter than `/` and `^`. `1/2x` is `1/(2x)`, while many readers expect `(1/2)x`.

## Example
```julia
half = 1/2x
```

## Alternative
```julia
half = 1/(2x)    # or (1/2)x
```

## Limitations
Fix keeps meaning and adds parentheses: `1/(2x)`.
"""
module Juxtaposition

using ...Facts

const NAME = :juxtaposition
const PATTERN = IndexedPattern(@pattern ~or({left} / {right}, {left}^{right}, {left} // {right}, {left} \ {right}))

"""Whether `node` is wrapped in parentheses in source: nearest non-space byte before it is `(`."""
function parenthesized(file::SyntaxFile, node::SyntaxNode)::Bool
    bytes = codeunits(file.text)
    index = span(file, node).first_byte - 1
    while index > 0 && bytes[index] in (UInt8(' '), UInt8('\t'))
        index -= 1
    end
    return index > 0 && bytes[index] == UInt8('(')
end

"""Findings for division or power whose right operand is unparenthesized juxtaposed product."""
function findings(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, match in matches(file, PATTERN)
        right = binding(match, :right)
        kind_name(right) == "juxtapose" && !parenthesized(file, right) || continue
        operator = call_head(match.node)
        explicit = source(file, binding(match, :left)) * operator * "(" * source(file, right) * ")"
        push!(
            found, finding(
                NAME, file, match.node; kind = :tight_juxtaposition, confidence = Confidence.definite,
                message = "`$(source(file, match.node))` means `$explicit`", label = "parsed as `$explicit`",
                why = "juxtaposition binds tighter than `$operator`; readers often read left to right",
                fix = replace_fix(file, match.node, explicit, Tier.safe), causes = [Label(span(file, right), "one factor")],
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.readability, [3], Stage.syntax, findings)

end
