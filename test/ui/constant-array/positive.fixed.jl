# ==> src/ConstantArrayPositive.jl
# runic: off
"""Fixture of `constant-array`: filled arrays that method only reads."""
module ConstantArrayPositive

using FillArrays: Ones
using FillArrays: Trues
using FillArrays: Fill
using FillArrays: Zeros
weighted(x::Vector{Float64}) = x' * Ones(length(x))

mask_count(n::Int) = count(Trues(n))

offset_total(x::Vector{Float64}) = sum(x .+ Fill(2.0, length(x)))

# Arithmetic result is new array, never operand.
row_sums(a::Matrix{Float64}) = a * Ones(size(a, 2))

# Concatenation copies elements: generic result type holds no operand.
padded(values::AbstractVector{T}, slots::Int) where {T <: Real} = [values; Zeros(T, slots - length(values))]

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
