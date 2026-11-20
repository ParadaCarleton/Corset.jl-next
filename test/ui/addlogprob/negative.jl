# runic: off
struct Halfplane{T} <: ContinuousMultivariateDistribution
    x::Vector{T}
end
Base.length(d::Halfplane) = length(d.x)
Distributions._logpdf(d::Halfplane, m::AbstractVector) = dot(m, d.x) < 0 ? -Inf : logpdf(MvNormal(zero(d.x), I), m)

@model function scale(x)
    σ ~ Exponential()
    x ~ filldist(Laplace(0, σ), length(x))
end

@model function halfplane(x)
    m ~ Halfplane(x)
    x ~ MvNormal(m, I)
end

# Name only, not call.
logprob_macro = Symbol("@addlogprob!")
