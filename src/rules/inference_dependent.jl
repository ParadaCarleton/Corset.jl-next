"""`inference-dependent` (F26): result depends on what compiler infers, so it changes between Julia versions."""
module InferenceDependent

using ...Facts

const NAME = Symbol("inference-dependent")
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
