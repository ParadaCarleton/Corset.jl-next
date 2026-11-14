using Base.Iterators: flatten
using LinearAlgebra: tr
pairs_of(lists::Vector) = collect(flatten(lists))
trace_of(matrix::Matrix{Float64}) = tr(matrix)
normalize(value::Int) = value
