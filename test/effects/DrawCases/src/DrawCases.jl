"""Dependency fixture: draws from default RNG without RNG argument, as Sobol.jl `next!` does past its point limit."""
module DrawCases

using Random: Random, AbstractRNG

"""Evenly spaced `values`; past `limit` entries, draws from default RNG instead."""
function fill_points!(values::Vector{Float64}, limit::Int)::Vector{Float64}
    length(values) > limit && return Random.rand!(values)
    values .= range(0, 1; length = length(values))
    return values
end

"""`values` filled with draws from `rng`."""
fill_points!(rng::AbstractRNG, values::Vector{Float64})::Vector{Float64} = Random.rand!(rng, values)

end
