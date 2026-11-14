using LinearAlgebra: tr
turn(left::Vector{Float64}, right::Vector{Float64}) = cross(left, right)
