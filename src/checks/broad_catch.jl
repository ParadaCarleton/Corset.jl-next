"""`broad-catch` (F59): `catch` that neither tests error type nor rethrows handles every error."""
module BroadCatch

using ...Facts

const NAME = Symbol("broad-catch")
"""Calls that narrow or pass on caught error."""
const NARROWING = Set(["rethrow", "throw", "isa", "error"])

"""Whether handler block `block` tests error type or passes error on."""
narrows(block)::Bool = any(node -> call_head(node) in NARROWING, descendants(block))

"""Findings for catch clauses that swallow every error, `InterruptException` included."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, clause in nodes_named(file, "catch")
        narrows(children_of(clause)[end]) && continue
        push!(
            found, finding(
                NAME, file, clause; kind = :untyped_catch, confidence = Confidence.definite,
                message = "`catch` handles every error", label = "no type test, no rethrow",
                why = "typos, `MethodError` and `InterruptException` vanish with intended errors",
                fix = manual_fix("handle expected type only: `e isa MyError || rethrow()`"),
            )
        )
    end
    return found
end

const ENTRY = CheckEntry(NAME, Group.correctness, [59], Family.A, run)

end
