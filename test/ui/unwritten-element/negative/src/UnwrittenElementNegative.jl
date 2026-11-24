# runic: off
"""Fixture of `unwritten-element`: arrays written before read, and arrays whose uses leave method."""
module UnwrittenElementNegative

copied(x::Vector{Float64}) = (y = similar(x); copyto!(y, x); sum(y))

filled(n::Int) = (a = Vector{Float64}(undef, n); fill!(a, 0.0); sum(a))

function looped(x::Vector{Float64})
    y = similar(x)
    for i in eachindex(y)
        y[i] = 2x[i]
    end
    return sum(y)
end

pair() = (a = Vector{Int}(undef, 2); a[1] = 1; a[2] = 2; sum(a))

first_only() = (a = Vector{Int}(undef, 2); a[1] = 1; a[1])

returned(n::Int) = Vector{Float64}(undef, n)

full() = (a = zeros(2); a[1] = 1.0; a[2] = 2.0; sum(a))

basis_entry() = (e = zeros(3); e[1] = 1.0; e[2])

end
