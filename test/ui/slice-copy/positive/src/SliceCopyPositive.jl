# runic: off
"""Fixture of `slice-copy`: slices that method only reads."""
module SliceCopyPositive

column_total(A::Matrix{Float64}, j::Int) = sum(A[:, j])

tail_max(x::Vector{Float64}) = maximum(x[2:end])

function picked_mean(x::Vector{Float64}, indices::Vector{Int})
    picked = x[indices]
    return sum(picked) / length(picked)
end

end
