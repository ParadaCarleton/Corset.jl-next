"""
`addlogprob` (F112): `@addlogprob!` adds density term outside `~`.

## Description
Reports DynamicPPL `@addlogprob!` calls, bare or through `Turing.` or `DynamicPPL.`.

## Rationale
DynamicPPL adds number to log likelihood. Prior term written so is lost under `Prior()` sampling and counted by
maximum likelihood. Term has no variable: `rand`, `predict` and `pointwise_loglikelihoods` skip it, so predictive
checks and PSIS-LOO miss it.

## Example
```julia
@model function scale(x)
    σ ~ Exponential()
    @addlogprob! sum(logpdf.(Laplace(0, σ), x))
end
```

## Alternative
```julia
@model function scale(x)
    σ ~ Exponential()
    x ~ filldist(Laplace(0, σ), length(x))
end
```
Density without Distributions.jl type: define `Distribution` subtype with `logpdf`, `rand` and support bounds.

## Limitations
Patterns match syntax as written: macro imported under other name passes.
"""
module Addlogprob

using ...Facts

const NAME = :addlogprob
const PATTERN = IndexedPattern(@pattern ~or(@addlogprob!({_}...), Turing.@addlogprob!({_}...), DynamicPPL.@addlogprob!({_}...)))

"""Findings for `@addlogprob!` calls."""
function findings(facts::FactSet)::Vector{Finding}
    return [
        finding(
            NAME, file, match.node; kind = :addlogprob, confidence = Confidence.definite,
            message = "`@addlogprob!` adds density term outside `~`",
            label = "term has no variable", why = "`Prior()` sampling, `rand`, `predict` and pointwise likelihoods skip or misfile it",
            fix = manual_fix("state term with `~`; for new density, define `Distribution` subtype with `logpdf` and `rand`"),
        ) for file in facts.files for match in matches(file, PATTERN)
    ]
end

const ENTRY = RuleEntry(NAME, Group.correctness, [112], Stage.syntax, findings)

end
