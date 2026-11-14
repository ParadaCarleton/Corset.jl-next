length_of(vector::Vector{Float64}) = norm(vector) + dot(vector, vector)
const UNIT = det([1.0;;])
