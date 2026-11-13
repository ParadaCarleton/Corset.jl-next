"""
`bracketed-range` (F2): range in brackets is one-element vector.

## Description
Reports vector literal whose only element is range: `[1:n]`.

## Rationale
`[1:n]` holds one range, not `n` numbers. Loop over it runs once, and `length` returns 1.

## Example
```julia
for i in [1:n]
    total += i
end
```

## Alternative
```julia
for i in 1:n
    total += i
end
values = collect(1:n)   # when vector is needed
```

## Limitations
Finding is `possible`: vector of ranges can be intended. Fix writes `collect(range)` with tier `likely`.
"""
module BracketedRange

using ...Facts

const NAME = Symbol("bracketed-range")
const PATTERN = IndexedPattern(@pattern [~or({start}:{stop}, {start}:{step}:{stop})])

"""Findings for vector literal whose only element is range; vector of ranges can be intended, so `possible`."""
function findings(facts::FactSet)::Vector{Finding}
    return [
        finding(
            NAME, file, match.node; kind = :range_vector, confidence = Confidence.possible,
            message = "`$(source(file, match.node))` is vector with one element, range `$(source(file, children_of(match.node)[1]))`",
            label = "one-element vector", why = "code that expects numbers gets range; `length` is 1",
            fix = replace_fix(file, match.node, "collect($(source(file, children_of(match.node)[1])))", Tier.likely),
        ) for file in facts.files for match in matches(file, PATTERN)
    ]
end

const ENTRY = RuleEntry(NAME, Group.correctness, [2], Stage.syntax, findings)

end
