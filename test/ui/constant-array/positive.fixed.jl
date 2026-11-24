# ==> src/ConstantArrayPositive.jl
# runic: off
"""Fixture of `constant-array`: filled arrays that method only reads."""
module ConstantArrayPositive

using FillArrays: Ones
using FillArrays: Trues
using FillArrays: Fill
weighted(x::Vector{Float64}) = x' * Ones(length(x))

mask_count(n::Int) = count(Trues(n))

offset_total(x::Vector{Float64}) = sum(x .+ Fill(2.0, length(x)))

module OwnOnes
struct Ones end
spread(n::Int) = sum(ones(n))
end

module Imported
# Stand-in for FillArrays.jl: fix checks module name only.
module FillArrays
Zeros(n::Int) = zeros(n)
end
using .FillArrays: Zeros
blank(n::Int) = sum(Zeros(n))
end

end
