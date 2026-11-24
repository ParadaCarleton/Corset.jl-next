# runic: off
"""Fixture of `temporary-array`: arrays that method reads more than once, returns, never builds, or concatenates."""
module TemporaryArrayNegative

spread(x::Vector{Float64}) = (y = abs.(x); maximum(y) - minimum(y))

returned(x::Vector{Float64}) = abs.(x)

lazy_total(x::Vector{Float64}) = sum(abs, x)

joined(x::Vector{Vector{Float64}}) = reduce(vcat, map(reverse, x))

qualified(x::Vector{Vector{Float64}}) = reduce(Base.hcat, map(reverse, x))

aliased(x::Vector{Vector{Float64}}) = (glue = vcat; reduce(glue, map(reverse, x)))

function looped(x::Vector{Float64})
    total = 0.0
    y = abs.(x)
    for _ in 1:3
        total += sum(y)
    end
    return total
end

end
