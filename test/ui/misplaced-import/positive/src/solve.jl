# Solvers.
solve(vector::Vector{Float64}) = norm(vector) / dot(vector, vector)
const UNIT = dot([1.0], [1.0])
