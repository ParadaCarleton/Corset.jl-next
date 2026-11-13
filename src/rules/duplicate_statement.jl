"""
`duplicate-statement` (F60): same statement twice in row.

## Description
Reports statement equal to statement directly before it, whitespace and docstrings ignored.

## Rationale
Repeated statement is usually copy-paste slip: second copy does nothing new, or does same work twice.

## Example
```julia
total += weight
total += weight
```

## Alternative
```julia
total += weight
count += 1
```

## Limitations
Finding is `possible`: repeated call such as `push!(queue, item)` can be intended.
"""
module DuplicateStatement

using ...Facts

const NAME = Symbol("duplicate-statement")

"""Source of `node` with whitespace runs collapsed and docstring dropped, for comparison."""
normalized(file::SyntaxFile, node)::String =
    kind_name(node) == "doc" ? normalized(file, children_of(node)[end]) : replace(source(file, node), r"\s+" => " ")

"""Findings for statement equal to statement right before it; repeated calls may be intended, so `possible`."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, block in [forms(file, "block"); forms(file, "toplevel")]
        statements = children_of(block)
        for (previous, statement) in zip(statements, Iterators.drop(statements, 1))
            normalized(file, previous) == normalized(file, statement) || continue
            push!(
                found, finding(
                    NAME, file, statement; kind = :repeated, confidence = Confidence.possible,
                    message = "statement repeats one before it", label = "same as previous statement",
                    why = "copy-paste slip: second copy redoes work, or was meant to differ",
                    fix = manual_fix("delete repeated statement, or change it to intended one"),
                    causes = [Label(span(file, previous), "first copy")],
                )
            )
        end
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [60], Stage.syntax, run)

end
