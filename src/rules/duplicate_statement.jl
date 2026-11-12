"""`duplicate-statement` (F60): same statement twice in row, usually copy-paste slip."""
module DuplicateStatement

using ...Facts

const NAME = Symbol("duplicate-statement")

"""Source of `node` with whitespace runs collapsed, for comparison."""
normalized(file::SyntaxFile, node)::String = replace(source(file, node), r"\s+" => " ")

"""Findings for statement equal to statement right before it; repeated calls may be intended, so `possible`."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, block in [nodes_named(file, "block"); nodes_named(file, "toplevel")]
        statements = children_of(block)
        for (previous, statement) in zip(statements, Iterators.drop(statements, 1))
            normalized(file, previous) == normalized(file, statement) || continue
            push!(
                found, finding(
                    NAME, file, statement; kind = :repeated, confidence = Confidence.possible,
                    message = "statement repeats one before it", label = "same as previous statement",
                    why = "copy-paste slip: second copy redoes work, or was meant to differ",
                    fix = manual_fix("delete repeated statement, or change it to intended one"),
                    causes = [Label(span(file, previous), "first copy")],
                )
            )
        end
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [60], Stage.syntax, run)

end
