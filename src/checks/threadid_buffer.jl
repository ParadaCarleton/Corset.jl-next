"""`threadid-buffer` (F68): buffer indexed by `threadid()`; task can migrate between threads."""
module ThreadidBuffer

using ...Facts

const NAME = Symbol("threadid-buffer")
const RULE = Rule(@pattern ~or({buffer}[threadid()], {buffer}[Threads.threadid()], {buffer}[Base.Threads.threadid()]))

"""Findings for indexing by current thread ID."""
function run(facts::FactSet)::Vector{Finding}
    return [
        finding(
            NAME, file, match.node; kind = :threadid_index, confidence = Confidence.definite,
            message = "`$(source(file, binding(match, :buffer)))` is indexed by thread ID",
            label = "task may switch thread between read and write",
            why = "tasks migrate between threads, so two tasks can share one slot and race",
            fix = manual_fix("keep state per task: chunk work and give each chunk its own buffer (OhMyThreads.jl)"),
        ) for file in facts.files for match in matches(file, RULE)
    ]
end

const ENTRY = CheckEntry(NAME, Group.correctness, [68], Family.A, run)

end
