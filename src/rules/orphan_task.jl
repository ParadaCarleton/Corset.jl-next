"""
`orphan-task` (F70): task never waited; its error vanishes.

## Description
Reports `@spawn` and `@async` whose task is dropped outside `@sync`.

## Rationale
Nobody waits on dropped task. Its exception never reaches caller, and program may finish before task does.

## Example
```julia
for file in files
    Threads.@spawn process(file)
end
```

## Alternative
```julia
@sync for file in files
    Threads.@spawn process(file)
end
```

## Limitations
Rule sees dropped statements only. Task stored in variable and never waited passes.
"""
module OrphanTask

using ...Facts

const NAME = Symbol("orphan-task")
"""Macros that start task and return it."""
const SPAWNING = Set(["@spawn", "@async"])

"""Whether `node` sits inside `@sync`, which waits for tasks started in its body."""
synced(node::SyntaxNode)::Bool = any(ancestor -> base_macro(ancestor) == "@sync", ancestors(node))

"""Findings for task-starting macros whose task is discarded outside `@sync`."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, call in forms(file, "macrocall")
        base_macro(call) in SPAWNING && discarded(call) && !synced(call) || continue
        push!(
            found, finding(
                NAME, file, call; kind = :discarded_task, confidence = Confidence.definite,
                message = "task from `$(macro_name(file, call))` is never waited", label = "task discarded",
                why = "exception inside task is stored in task; nobody reads it, so failure stays silent",
                fix = manual_fix("keep task and `wait` or `fetch` it, or wrap starts in `@sync`"),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [70], Stage.syntax, run)

end
