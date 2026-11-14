# runic: off
# Struct holds byte 223, where public `Model` constructor starts.
"""Model for Julia before 1.6; package never loads this file."""
struct Model
    weights::Vector{Float64}
    bias::Float64
    scale::Float64
end
