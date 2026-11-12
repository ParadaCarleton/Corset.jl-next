"""`bracketed-range` (F2): `[1:3]` is one-element vector holding range."""
module BracketedRange

using ...Facts

const NAME = Symbol("bracketed-range")
const PATTERN = IndexedPattern(@pattern [~or({start}:{stop}, {start}:{step}:{stop})])

"""Findings for vector literal whose only element is range; vector of ranges can be intended, so `possible`."""
function run(facts::FactSet)::Vector{Finding}
    return [
        finding(
            NAME, file, match.node; kind = :range_vector, confidence = Confidence.possible,
            message = "`$(source(file, match.node))` is vector with one element, range `$(source(file, children_of(match.node)[1]))`",
            label = "one-element vector", why = "code that expects numbers gets range; `length` is 1",
            fix = replace_fix(file, match.node, "collect($(source(file, children_of(match.node)[1])))", Tier.likely),
        ) for file in facts.files for match in matches(file, PATTERN)
    ]
end

const ENTRY = RuleEntry(NAME, Group.correctness, [2], Family.A, run)

end
