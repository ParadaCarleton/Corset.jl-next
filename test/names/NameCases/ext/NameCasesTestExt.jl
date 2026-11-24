"""Extension of `NameCases`: its own fill helper keeps `rand!(rng, s, x)` order, like `DistributionsTestExt.__rand!`."""
module NameCasesTestExt

using Random: AbstractRNG
using Test: Test

"""Fill `items` after sampler `scale`."""
_rand!(generator::AbstractRNG, scale::Base.RefValue{Float64}, items::Vector{Float64})::Vector{Float64} = (items .= rand(generator) .* scale[]; items)

end
