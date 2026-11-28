# runic: off
module HiddenInputLibrary

using DrawCases: DrawCases
using Random: AbstractRNG

# Dependency draws from default RNG past limit: label names its line.
points(count::Int) = DrawCases.fill_points!(zeros(count), 100)

# Caller RNG reaches dependency draw.
seeded_points(rng::AbstractRNG, count::Int) = DrawCases.fill_points!(rng, zeros(count))

end
