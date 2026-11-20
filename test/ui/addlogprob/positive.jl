# runic: off
@model function scale(x)
    σ ~ Exponential()
    @addlogprob! sum(logpdf.(Laplace(0, σ), x))
end

@model function shifted(x)
    μ ~ Normal()
    Turing.@addlogprob!(logpdf(Gamma(2, 1), abs(μ)))
    x ~ Normal(μ, 1)
end

@model function halfplane(x)
    m ~ MvNormal(zero(x), I)
    if dot(m, x) < 0
        DynamicPPL.@addlogprob! (; loglikelihood = -Inf)
        return
    end
    x ~ MvNormal(m, I)
end
