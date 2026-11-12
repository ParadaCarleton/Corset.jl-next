"""`where-binding` (F4): in `f(x::T)::T where {T} = …`, `where` binds result type, not method."""
module WhereBinding

using ...Facts

const NAME = Symbol("where-binding")
const PATTERN = IndexedPattern(@pattern {signature}::{annotation})

"""Whether `node` is signature of short-form method definition `signature = body`."""
function defines_method(node)::Bool
    parent = parent_of(node)
    return !isnothing(parent) && kind_name(parent) == "function" && children_of(parent)[1] === node
end

"""Findings for short-form definitions whose `where` clause attaches to result annotation."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, match in matches(file, PATTERN)
        annotated = children_of(match.node)
        clause = annotated[2]
        kind_name(clause) == "where" && defines_method(match.node) || continue
        result, parameters = children_of(clause)[1], children_of(clause)[2:end]
        replacement = "(" * source(file, annotated[1]) * "::" * source(file, result) * ") where " *
            join((source(file, parameter) for parameter in parameters), " ")
        push!(
            found, finding(
                NAME, file, match.node; kind = :result_where, confidence = Confidence.definite,
                message = "`where` binds result type `$(source(file, result))`, not method",
                label = "`where` attaches to result annotation", why = "method gets no type parameter: call errors, or uses global of same name",
                fix = replace_fix(file, match.node, replacement, Tier.safe),
                causes = [Label(span(file, clause), "parsed as `$(source(file, result)) where …`")],
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [4], Stage.syntax, run)

end
