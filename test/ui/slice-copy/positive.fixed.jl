# ==> src/SliceCopyPositive.jl
# runic: off
"""Fixture of `slice-copy`: slices that method only reads."""
module SliceCopyPositive

column_total(A::Matrix{Float64}, j::Int) = sum(@view(A[:, j]))

tail_max(x::Vector{Float64}) = maximum(@view(x[2:end]))

function picked_mean(x::Vector{Float64}, indices::Vector{Int})
    picked = @view(x[indices])
    return sum(picked) / length(picked)
end

end
