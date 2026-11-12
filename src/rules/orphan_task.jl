"""`orphan-task` (F70): task started and never waited; its error vanishes."""
module OrphanTask

using ...Facts

const NAME = Symbol("orphan-task")
"""Macros that start task and return it."""
const SPAWNING = Set(["@spawn", "@async"])

"""Macro name of `macrocall` node, last component for dotted name (`Threads.@spawn`)."""
macro_of(node)::Union{Nothing, String} =
    (name = children_of(node)[1]; leaf_value(isempty(children_of(name)) ? name : children_of(name)[end]))

"""Whether value of `node` is dropped: statement in file or loop body, or non-last statement of other block."""
function discarded(node)::Bool
    parent = parent_of(node)
    isnothing(parent) && return false
    kind_name(parent) == "toplevel" && return true
    kind_name(parent) == "block" || return false
    owner = parent_of(parent)
    !isnothing(owner) && kind_name(owner) in ("for", "while") && return true
    return children_of(parent)[end] !== node
end

"""Whether `node` sits inside `@sync`, which waits for tasks started in its body."""
synced(node)::Bool = any(ancestor -> kind_name(ancestor) == "macrocall" && macro_of(ancestor) == "@sync", ancestors(node))

"""Findings for task-starting macros whose task is discarded outside `@sync`."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, call in nodes_named(file, "macrocall")
        macro_of(call) in SPAWNING && discarded(call) && !synced(call) || continue
        push!(
            found, finding(
                NAME, file, call; kind = :discarded_task, confidence = Confidence.definite,
                message = "task from `$(macro_of(call))` is never waited", label = "task discarded",
                why = "exception inside task is stored in task; nobody reads it, so failure stays silent",
                fix = manual_fix("keep task and `wait` or `fetch` it, or wrap starts in `@sync`"),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [70], Stage.syntax, run)

end
