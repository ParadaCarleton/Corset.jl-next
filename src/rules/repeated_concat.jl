"""
`repeated-concat` (F44): loop concatenates one piece at a time.

## Description
Reports `a = vcat(a, piece)`, `a = [a; piece]`, and same pattern with `hcat`, `cat` or `string`, inside loop.

## Rationale
Each step copies all earlier pieces, so total work grows with square of length.

## Example
```julia
result = Int[]
for part in parts
    result = vcat(result, part)
end
```

## Alternative
```julia
result = Int[]
for part in parts
    append!(result, part)
end
```

## Limitations
None known.
"""
module RepeatedConcat

using ...Facts

const NAME = Symbol("repeated-concat")
"""Calls that copy first argument to append."""
const CONCATS = Set(["vcat", "hcat", "cat", "string"])

"""Whether `node` sits inside `for` or `while` body."""
in_loop(node::SyntaxNode)::Bool = any(ancestor -> kind_name(ancestor) in ("for", "while"), ancestors(node))

"""Findings for `a = vcat(a, …)` and `a = [a; …]` inside loops: each step copies whole `a`."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, assignment in forms(file, "=")
        target, value = children_of(assignment)[1], children_of(assignment)[end]
        name = identifier_name(target)
        isnothing(name) && continue
        grows = (call_head(value) in CONCATS && identifier_name(children_of(value)[2]) == name) ||
            (kind_name(value) == "vcat" && identifier_name(children_of(value)[1]) == name)
        grows && in_loop(assignment) || continue
        push!(
            found, finding(
                NAME, file, assignment; kind = :concatenation, confidence = Confidence.definite,
                message = "`$name` is copied on every loop step", label = "builds new `$name` from old one",
                why = "each step copies all earlier pieces, so total work grows with square of length",
                fix = manual_fix("`append!` or `push!` into `$name`, or collect pieces and join once (`reduce(vcat, pieces)`)"),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.performance, [44], Stage.syntax, run)

end
