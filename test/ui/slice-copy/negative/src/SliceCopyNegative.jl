# runic: off
"""Fixture of `slice-copy`: slices that change or leave method, loops that reuse slice, and views."""
module SliceCopyNegative

# Caller owns returned copy.
tail(x::Vector{Float64}) = x[2:end]

# Write to copy must not reach parent.
zeroed_total(x::Vector{Float64}) = (t = x[1:2]; t[1] = 0.0; sum(t))

padded_total(x::Vector{Float64}) = (t = x[1:2]; push!(t, 0.0); sum(t))

# Loop reads copy many times: contiguous copy can read faster than strided view.
function repeated(A::Matrix{Float64}, n::Int)
    row = A[1, :]
    total = 0.0
    for _ in 1:n
        total += sum(row)
    end
    return total
end

element(x::Vector{Float64}, i::Int) = x[i]

# `String` takes memory of byte vector: view would copy instead.
prefix_text(bytes::Vector{UInt8}) = String(bytes[1:2])

viewed(A::Matrix{Float64}, j::Int) = sum(@view A[:, j])

end
