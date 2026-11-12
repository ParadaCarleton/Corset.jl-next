"""
`inference-dependent` (F26): behavior depends on inference result.

## Description
Reports calls to `Core.Compiler.return_type`, `Base.return_types`, `Base.infer_return_type` and `Base.promote_op`.

## Rationale
Inference may widen result at any time: new Julia version, other load order, or changed heuristics. Code that branches on result then takes other path or allocates other type.

## Example
```julia
T = Base.promote_op(+, eltype(a), eltype(b))
result = Vector{T}(undef, n)
```

## Alternative
```julia
result = map(+, a, b)
```

## Limitations
None known.
"""
module InferenceDependent

using ...Facts

const NAME = Symbol("inference-dependent")
# corset: allow inference-dependent -- Argus pattern source is data
const PATTERN = IndexedPattern(
    @pattern ~or(
        Core.Compiler.return_type({_}...), Base.return_types({_}...), Base.infer_return_type({_}...),
        Base.promote_op({_}...), Core.Compiler.infer_return_type({_}...),
    )
)

"""Findings for calls that expose inference results as values."""
function run(facts::FactSet)::Vector{Finding}
    return [
        finding(
            NAME, file, match.node; kind = :inference_query, confidence = Confidence.definite,
            message = "result of `$(source(file, children_of(match.node)[1]))` depends on compiler inference",
            label = "value can change with Julia version or compiler heuristics",
            why = "inference may widen result at any time; code then takes other branch or allocates other type",
            fix = manual_fix("compute type from values (`typeof(f(x))`), or document fallback for wide result"),
        ) for file in facts.files for match in matches(file, PATTERN)
    ]
end

const ENTRY = RuleEntry(NAME, Group.composability, [26], Stage.syntax, run)

end
