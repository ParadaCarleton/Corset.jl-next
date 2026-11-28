# runic: off
module HiddenInputLibrary

using DrawCases: DrawCases
using Random: AbstractRNG

# Dependency draws from default RNG past limit: label names its line.
points(count::Int) = DrawCases.fill_points!(zeros(count), 100)

# Dependency offers RNG method: fix passes RNG, and reports upstream if dependency still draws.
mixed(values::Vector{Float64}) = DrawCases.shuffled(values)

# Caller RNG reaches dependency draw.
seeded_points(rng::AbstractRNG, count::Int) = DrawCases.fill_points!(rng, zeros(count))

end
