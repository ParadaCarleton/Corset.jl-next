"""
`pinned-task` (F99): task pinned to one thread.

## Description
Reports `@async`, task construction with `Task(f)` or `@task`, and `@threads :static`.

## Rationale
Pinned task runs only on its thread, even when other threads are idle.
`@async` also pins task that starts it, and so does `schedule` of sticky `Task`.
`:static` schedule throws when caller runs on thread other than 1 or inside another `@threads` loop.

## Example
```julia
task = @async fetch_data(url)
```

## Alternative
```julia
task = Threads.@spawn fetch_data(url)
```

## Limitations
`Task` and `@task` pass when same block later sets `task.sticky = false` on assigned name.
Fix for `@async` writes `Threads.@spawn` with tier `breaking`: task then runs in parallel, so shared state may race.
"""
module PinnedTask

using ...Facts

const NAME = Symbol("pinned-task")
"""Finding kind of each macro name as written."""
const MACROS = Dict(
    "@async" => :async, "Threads.@async" => :async, "Base.@async" => :async, "Base.Threads.@async" => :async,
    "@task" => :task, "Base.@task" => :task,
    "@threads" => :static_schedule, "Threads.@threads" => :static_schedule, "Base.Threads.@threads" => :static_schedule,
)

"""Byte of last `name.sticky = false` in each block, keyed by block identity and name."""
function unpinned(file::SyntaxFile)::Dict{Tuple{UInt, String}, Int}
    found = Dict{Tuple{UInt, String}, Int}()
    for assignment in forms(file, "=")
        target, assigned = children_of(assignment)[1], children_of(assignment)[end]
        kind_name(target) == "." && identifier_name(children_of(target)[end]) == "sticky" && leaf_value(assigned) == "false" || continue
        name = identifier_name(children_of(target)[1])
        isnothing(name) || (found[(objectid(parent_of(assignment)), name)] = span(file, assignment).first_byte)
    end
    return found
end

"""Whether task from `node` is assigned to name that same block later sets `name.sticky = false`."""
function opted_out(file::SyntaxFile, node::SyntaxNode, unpinned::Dict{Tuple{UInt, String}, Int})::Bool
    assignment = parent_of(node)
    kind_name(assignment) == "=" && children_of(assignment)[end] === node || return false
    name = identifier_name(children_of(assignment)[1])
    return !isnothing(name) && get(unpinned, (objectid(parent_of(assignment)), name), 0) > span(file, assignment).first_byte
end

"""Whether `@threads` call `node` passes `:static` schedule."""
function static_schedule(node::SyntaxNode)::Bool
    parts = children_of(node)
    return length(parts) >= 3 && kind_name(parts[2]) == "quote" && identifier_name(children_of(parts[2])[1]) == "static"
end

"""Finding for sticky task created by `node`, `Task(f)` call or `@task`, written as `name`."""
task_finding(file::SyntaxFile, node::SyntaxNode, name::String)::Finding = finding(
    NAME, file, node; kind = :task, confidence = Confidence.definite,
    message = "`$name` creates sticky task; `schedule` pins it and caller to one thread", label = "sticky by default",
    why = "sticky task runs only on scheduling thread; scheduling it also pins calling task",
    fix = manual_fix("start task with `Threads.@spawn`, or set `task.sticky = false` before `schedule`"),
)

"""Findings for `@async`, sticky task construction, and `@threads :static`."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files
        sticky_off = unpinned(file)
        for node in forms(file, "macrocall")
            name = macro_name(file, node)
            kind = get(MACROS, name, nothing)
            if kind == :async
                push!(
                    found, finding(
                        NAME, file, node; kind, confidence = Confidence.definite,
                        message = "`$name` pins task and its parent to current thread", label = "sticky task",
                        why = "pinned task waits for its thread while others idle; parent task stays pinned for its whole life",
                        fix = Fix("replace `$name` with `Threads.@spawn`", [Edit(macro_span(file, node), "Threads.@spawn")], Tier.breaking),
                    )
                )
            elseif kind == :task && !opted_out(file, node, sticky_off)
                push!(found, task_finding(file, node, name))
            elseif kind == :static_schedule && static_schedule(node)
                push!(
                    found, finding(
                        NAME, file, children_of(node)[2]; kind, confidence = Confidence.definite,
                        message = "`$name :static` pins one task to each thread", label = "static schedule",
                        why = "`:static` throws when caller runs on thread other than 1 or inside another `@threads` loop",
                        fix = manual_fix("remove `:static`; keep state per chunk of work, not per `threadid()`"),
                    )
                )
            end
        end
        for node in forms(file, "call")
            call_head(node) == "Task" && !opted_out(file, node, sticky_off) && push!(found, task_finding(file, node, "Task"))
        end
    end
    return sort!(found; by = finding -> finding.primary.span.first_byte)
end

const ENTRY = RuleEntry(NAME, Group.composability, [99], Stage.syntax, run)

end
