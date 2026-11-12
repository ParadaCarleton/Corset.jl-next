"""`threadid-buffer` (F68): buffer indexed by `threadid()`; task can migrate between threads."""
module ThreadidBuffer

using ...Facts

const NAME = Symbol("threadid-buffer")
const PATTERN = IndexedPattern(@pattern ~or({buffer}[threadid()], {buffer}[Threads.threadid()], {buffer}[Base.Threads.threadid()]))

"""Macros that run body on several tasks."""
const THREADED = Set(["@threads", "@spawn", "@async"])

"""Whether `node` sits inside threaded macro call (`@threads`, `Threads.@threads`, `@spawn`)."""
function threaded(node)::Bool
    return any(ancestors(node)) do ancestor
        kind_name(ancestor) == "macrocall" || return false
        name = children_of(ancestor)[1]
        return leaf_value(isempty(children_of(name)) ? name : children_of(name)[end]) in THREADED
    end
end

"""Findings for indexing by current thread ID: `definite` inside threaded macro, else `possible`."""
function run(facts::FactSet)::Vector{Finding}
    return [
        finding(
            NAME, file, match.node; kind = :threadid_index,
            confidence = threaded(match.node) ? Confidence.definite : Confidence.possible,
            message = "`$(source(file, binding(match, :buffer)))` is indexed by thread ID",
            label = "task may switch thread between read and write",
            why = "tasks migrate between threads, so two tasks can share one slot and race",
            fix = manual_fix("keep state per task: chunk work and give each chunk its own buffer (OhMyThreads.jl)"),
        ) for file in facts.files for match in matches(file, PATTERN)
    ]
end

const ENTRY = RuleEntry(NAME, Group.correctness, [68], Family.A, run)

end
