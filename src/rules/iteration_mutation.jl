"""
`iteration-mutation` (F48): collection written inside loop that iterates it.

## Description
Reports `!` call or field store inside `for` loop that writes collection loop iterates. View of collection counts:
`for k in keys(d)` iterates `d`. Size change of same object (`push!`, `delete!`, `empty!`) is `definite`; other write,
or object that can be other, is `possible`. Writes to elements below collection never count.

## Rationale
Loop reads collection by index or slot between steps. Insertion can rehash dictionary or move array elements, so loop
skips or repeats elements, or throws. Base `filter!(f, ::AbstractDict)` warns: "dictionary types may not support
mutation during iteration".

## Example
```julia
function drop_empty!(groups::AbstractDict{String, Vector{Int}})
    for name in keys(groups)
        isempty(groups[name]) && delete!(groups, name)
    end
    return groups
end
```

## Alternative
```julia
drop_empty!(groups::AbstractDict{String, Vector{Int}}) = filter!(((_, members),) -> !isempty(members), groups)
```

## Limitations
`setindex!` on array replaces element: no finding. Deletion from `Dict`, `IdDict`, `WeakKeyDict`, `Set`, `IdSet` and
`BitSet` gives no finding: Base deletes from each while iterating it. Closure that consuming call runs
(`foreach(x -> push!(v, x), v)`) stays unseen: its loop is in library code. Write that reaches collection only through
object name tier cannot pin (element of `zip` result) goes to coverage line. Fix is `manual`.
"""
module IterationMutation

using ...Facts

const NAME = Symbol("iteration-mutation")

"""Findings for each write to collection inside loop that iterates it."""
function findings(facts::FactSet)::Vector{Finding}
    effects = facts.effects
    isnothing(effects) && return Finding[]
    return [
        Finding(
            NAME, :iteration_mutation, write.confidence, "`$(write.callee)` changes collection while loop iterates it",
            Label(write.write, "writes collection"), [Label(write.loop, "loop iterates collection")],
            "loop can skip or repeat elements, or throw, when collection changes between steps",
            manual_fix("iterate copy (`collect(keys(d))`), or collect changes and apply them after loop"),
        ) for method in effects.methods for write in method.loop_writes
    ]
end

const ENTRY = RuleEntry(NAME, Group.correctness, [48], Stage.effects, findings)

end
