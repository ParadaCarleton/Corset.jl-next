"""`juxtaposition` (F3): `1/2x` is `1/(2x)` and `2^2x` is `2^(2x)`; juxtaposition binds tighter than reader expects."""
module Juxtaposition

using ...Facts

const NAME = :juxtaposition
const PATTERN = IndexedPattern(@pattern ~or({left} / {right}, {left}^{right}, {left} // {right}, {left} \ {right}))

"""Whether `node` is wrapped in parentheses in source: nearest non-space byte before it is `(`."""
function parenthesized(file::SyntaxFile, node)::Bool
    bytes = codeunits(file.text)
    index = span(file, node).first_byte - 1
    while index > 0 && bytes[index] in (UInt8(' '), UInt8('\t'))
        index -= 1
    end
    return index > 0 && bytes[index] == UInt8('(')
end

"""Findings for division or power whose right operand is unparenthesized juxtaposed product."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, match in matches(file, PATTERN)
        right = binding(match, :right)
        kind_name(right) == "juxtapose" && !parenthesized(file, right) || continue
        operator = call_head(match.node)
        explicit = source(file, binding(match, :left)) * operator * "(" * source(file, right) * ")"
        push!(
            found, finding(
                NAME, file, match.node; kind = :tight_juxtaposition, confidence = Confidence.definite,
                message = "`$(source(file, match.node))` means `$explicit`", label = "parsed as `$explicit`",
                why = "juxtaposition binds tighter than `$operator`; readers often read left to right",
                fix = replace_fix(file, match.node, explicit, Tier.safe), causes = [Label(span(file, right), "one factor")],
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [3], Family.A, run)

end
