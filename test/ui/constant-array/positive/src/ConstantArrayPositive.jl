# runic: off
"""Fixture of `constant-array`: filled arrays that method only reads."""
module ConstantArrayPositive

weighted(x::Vector{Float64}) = x' * ones(length(x))

mask_count(n::Int) = count(trues(n))

offset_total(x::Vector{Float64}) = sum(x .+ fill(2.0, length(x)))

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
blank(n::Int) = sum(zeros(n))
end

end
