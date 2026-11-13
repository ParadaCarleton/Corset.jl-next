"""
`pinned-task` (F99): task pinned to one thread.

## Description
Reports `@async`, task construction with `Task(f)` or `@task`, and `@threads :static`, in package code only.
Script owns whole process and picks its own threads, so rule skips it.

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
`Task` and `@task` pass when same block sets `task.sticky = false` on assigned name before `schedule`, `yield` or `yieldto` starts it.
Fix for `@async` writes `Threads.@spawn` with tier `breaking`: task then runs in parallel, so shared state may race.
"""
module PinnedTask

using ...Facts

const NAME = Symbol("pinned-task")
"""Finding kind of each Base macro."""
const MACROS = Dict("@async" => :async, "@task" => :task, "@threads" => :static_schedule)

"""Nearest block or file around `node`, where statements run in order; `return x.sticky = false` still runs in it."""
statement_block(node::SyntaxNode)::SyntaxNode = first(ancestor for ancestor in ancestors(node) if kind_name(ancestor) in ("block", "toplevel"))

"""Functions that start task passed first; `task.sticky = false` after them leaves task pinned."""
const STARTS = ("schedule", "yield", "yieldto")

"""Opt-out sites of file: bytes of `name.sticky = false` by block identity and name; bytes of calls that start task `name`."""
struct Unpins
    sticky_off::Dict{Tuple{UInt, String}, Vector{Int}}
    starts::Dict{String, Vector{Int}}
end

"""Opt-out sites of `file`, in source order."""
function unpins(file::SyntaxFile)::Unpins
    sticky_off, starts = Dict{Tuple{UInt, String}, Vector{Int}}(), Dict{String, Vector{Int}}()
    for assignment in forms(file, "=")
        target, assigned = children_of(assignment)[1], children_of(assignment)[end]
        kind_name(target) == "." && identifier_name(children_of(target)[end]) == "sticky" && leaf_value(assigned) == "false" || continue
        name = identifier_name(children_of(target)[1])
        isnothing(name) || push!(get!(Vector{Int}, sticky_off, (objectid(statement_block(assignment)), name)), span(file, assignment).first_byte)
    end
    for call in forms(file, "call")
        call_head(call) in STARTS && length(children_of(call)) >= 2 || continue
        name = identifier_name(children_of(call)[2])
        isnothing(name) || push!(get!(Vector{Int}, starts, name), span(file, call).first_byte)
    end
    return Unpins(sticky_off, starts)
end

"""Whether task from `node` is assigned to name that same block sets `name.sticky = false` for before any call starts it."""
function opted_out(file::SyntaxFile, node::SyntaxNode, unpins::Unpins)::Bool
    assignment = parent_of(node)
    kind_name(assignment) == "=" && children_of(assignment)[end] === node || return false
    name = identifier_name(children_of(assignment)[1])
    isnothing(name) && return false
    assigned, sticky_off = span(file, assignment).first_byte, get(unpins.sticky_off, (objectid(statement_block(assignment)), name), Int[])
    index = findfirst(>(assigned), sticky_off)
    return !isnothing(index) && !any(start -> assigned < start < sticky_off[index], get(unpins.starts, name, Int[]))
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
        file.role == Role.package || continue
        sites = unpins(file)
        for node in forms(file, "macrocall")
            name = macro_name(file, node)
            kind = get(MACROS, base_macro(node), nothing)
            if kind == :async
                push!(
                    found, finding(
                        NAME, file, node; kind, confidence = Confidence.definite,
                        message = "`$name` pins task and its parent to current thread", label = "sticky task",
                        why = "pinned task waits for its thread while others idle; parent task stays pinned for its whole life",
                        fix = Fix("replace `$name` with `Threads.@spawn`", [Edit(macro_span(file, node), "Threads.@spawn")], Tier.breaking),
                    )
                )
            elseif kind == :task && !opted_out(file, node, sites)
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
            call_head(node) == "Task" && !opted_out(file, node, sites) && push!(found, task_finding(file, node, "Task"))
        end
    end
    return sort!(found; by = finding -> finding.primary.span.first_byte)
end

const ENTRY = RuleEntry(NAME, Group.composability, [99], Stage.syntax, run)

end
