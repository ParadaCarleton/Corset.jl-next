# Message words, labels and fixes of weak-value findings (`Disruption`).

"""Irrational constants float literal can spell, with name of each: Base names, then IrrationalConstants.jl names."""
const IRRATIONALS = (
    (π, "π"), (ℯ, "ℯ"), (Base.MathConstants.γ, "γ"), (Base.MathConstants.φ, "φ"), (2π, "twoπ"), (π / 2, "halfπ"),
    (π / 4, "quartπ"), (1 / π, "invπ"), (sqrt(2), "sqrt2"), (1 / sqrt(2), "invsqrt2"), (sqrt(π), "sqrtπ"),
    (sqrt(2π), "sqrt2π"), (1 / sqrt(2π), "invsqrt2π"), (log(2), "logtwo"), (log(10), "logten"), (log(π), "logπ"),
)

"""Base names of `IRRATIONALS`; others come from IrrationalConstants.jl."""
const BASE_IRRATIONALS = ("π", "ℯ", "γ", "φ")

"""Name of irrational constant float `value` spells to five significant digits; `nothing` when none."""
function irrational_name(value::Real)::Union{Nothing, String}
    for (constant, name) in IRRATIONALS
        isapprox(value, Float64(constant); rtol = 1.0e-5) && return name
    end
    return nothing
end

"""Words for weak value of `disruption` in message: literal `0.5`, constant `HALF`, conversion to `Float64`, or start value of `s`."""
function weak_words(disruption::Disruption)::String
    disruption.kind == Weak.literal && return "literal `$(disruption.value)`"
    disruption.kind == Weak.constant && return "constant `$(disruption.value)`"
    disruption.kind == Weak.name && return "conversion to `$(disruption.weak_type)`"
    return "start value of `$(disruption.variable)`"
end

"""Label at weak value of `disruption`: type weak value keeps for every input type."""
function weak_label(disruption::Disruption)::String
    disruption.kind == Weak.name && return "converts every input type to `$(disruption.weak_type)`"
    disruption.kind == Weak.variable && return "starts `$(disruption.variable)` as `$(disruption.weak_type)`"
    return "`$(disruption.weak_type)` for every input type"
end

"""
Fix of `disruption`: irrational constant for float literal that spells one (`manual`); conversion to input type
(`likely`: callers see input type), `manual` where inference stage gives no `converted` text or literal leaves
`Float32` range: `oftype(x, 1e39)` gives `Inf32`.
"""
function weak_fix(disruption::Disruption)::Fix
    irrational = isnothing(disruption.float) ? nothing : irrational_name(something(disruption.float))
    if !isnothing(irrational)
        package = irrational in BASE_IRRATIONALS ? "" : " from IrrationalConstants.jl"
        return manual_fix("use irrational `$irrational`$package; it takes input type")
    end
    value = disruption.float
    if !isnothing(value) && !iszero(value) && isfinite(value)
        narrowed = Float32(value)
        isinf(narrowed) && return manual_fix("`$(disruption.value)` overflows `Float32` input: rescale, or opt out to keep `Float64`")
        iszero(narrowed) && return manual_fix("`$(disruption.value)` rounds to zero in `Float32` input: rescale, or opt out to keep `Float64`")
    end
    converted = disruption.converted
    isnothing(converted) || return Fix("convert to input type: `$converted`", [Edit(disruption.span, converted)], Tier.likely)
    disruption.kind == Weak.name && return manual_fix("drop conversion, or keep input type with `float(x)` or `oftype(x, y)`")
    disruption.kind == Weak.variable && return manual_fix("start `$(disruption.variable)` with input type, as in `zero(T)` or `zero(eltype(xs))`")
    return manual_fix("convert `$(disruption.value)` to input type, as in `oftype(x, $(disruption.value))` or `T($(disruption.value))`")
end

"""Cause labels of `disruption`: meeting call, then statement where type changes as `exit_text` says; equal spans merge."""
function weak_causes(disruption::Disruption, exit_text::String)::Vector{Label}
    meeting = "meets `$(disruption.input)` input here"
    disruption.meeting == disruption.exit_span && return [Label(disruption.meeting, "$meeting and $exit_text")]
    return [Label(disruption.meeting, meeting), Label(disruption.exit_span, exit_text)]
end
