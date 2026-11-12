"""`quadratic` (F43, F44): search inside loop over same collection; concatenation one piece at a time."""
module Quadratic

using ...Facts

const NAME = :quadratic
"""Calls that scan whole collection given as last argument."""
const SCANS = Set(["in", "∈", "findfirst", "findlast", "findall", "count", "indexin", "occursin"])
"""Calls that copy first argument to append."""
const CONCATS = Set(["vcat", "hcat", "cat", "string"])

"""Whether `node` sits inside `for` or `while` body."""
in_loop(node)::Bool = any(ancestor -> kind_name(ancestor) in ("for", "while"), ancestors(node))

"""Findings for `a = vcat(a, …)` and `a = [a; …]` inside loops: each step copies whole `a`."""
function concatenations(file::SyntaxFile)::Vector{Finding}
    found = Finding[]
    for assignment in nodes_named(file, "=")
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

"""Findings for scans of loop's own collection inside loop body; collection may be small, so `possible`."""
function scans(file::SyntaxFile)::Vector{Finding}
    found = Finding[]
    for loop in nodes_named(file, "for")
        clauses = children_of(children_of(loop)[1])
        collections = filter(!isnothing, [identifier_name(children_of(clause)[end]) for clause in clauses])
        for node in descendants(children_of(loop)[end])
            call_head(node) in SCANS || continue
            scanned = identifier_name(children_of(node)[end])
            scanned in collections || continue
            push!(
                found, finding(
                    NAME, file, node; kind = :scan, confidence = Confidence.possible,
                    message = "`$(source(file, node))` scans `$scanned` on every step of loop over `$scanned`",
                    label = "linear search per element", why = "nested scan makes loop quadratic in length of `$scanned`",
                    fix = manual_fix("build `Set($scanned)` or `Dict` once before loop"),
                    causes = [Label(span(file, children_of(loop)[1]), "loop over `$scanned`")],
                )
            )
        end
    end
    return found
end

"""Findings of both quadratic kinds."""
run(facts::FactSet)::Vector{Finding} = reduce(vcat, ([concatenations(file); scans(file)] for file in facts.files); init = Finding[])

const ENTRY = CheckEntry(NAME, Group.performance, [43, 44], Family.A, run)

end
