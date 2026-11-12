"""
`ambiguous-concat` (F1): space before sign in array literal starts new element.

## Description
Reports array literal row where space before `-` or `+` splits one expression into two elements: `[a -b]`.

## Rationale
Inside brackets, `a -b` is two elements and `a - b` is one. Spacing silently changes shape and length of result.

## Example
```julia
offsets = [width -margin]
```

## Alternative
```julia
offsets = [width - margin]   # difference
offsets = [width, -margin]   # two elements
```

## Limitations
Finding is `possible`: row of signed numbers can be intended.
"""
module AmbiguousConcat

using ...Facts

const NAME = Symbol("ambiguous-concat")

"""Whether `node` source starts with sign directly followed by operand, and space precedes it in `text`."""
function signed_after_space(file::SyntaxFile, node)::Bool
    bytes = codeunits(file.text)
    first = span(file, node).first_byte
    return first > 1 && bytes[first] in (UInt8('-'), UInt8('+')) && bytes[first - 1] in (UInt8(' '), UInt8('\t')) &&
        first < length(bytes) && !(bytes[first + 1] in (UInt8(' '), UInt8('\t')))
end

"""Findings for one-row concatenation with signed element after space; matrix may be intended, so `possible`."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, row in nodes_named(file, "hcat")
        elements = children_of(row)
        for (previous, element) in zip(elements, Iterators.drop(elements, 1))
            signed_after_space(file, element) || continue
            joined = source(file, previous) * " " * source(file, element)[1:1] * " " * source(file, element)[2:end]
            push!(
                found, finding(
                    NAME, file, row; kind = :space_sign, confidence = Confidence.possible,
                    message = "`$(source(file, row))` concatenates `$(source(file, element))` as new element",
                    label = "1×$(length(elements)) matrix", why = "space before sign starts new element; `$joined` would subtract",
                    fix = manual_fix("write `[$(source(file, previous)), $(source(file, element))]` for vector, `[$joined]` for arithmetic"),
                    causes = [Label(span(file, element), "separate element")],
                )
            )
        end
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [1], Stage.syntax, run)

end
