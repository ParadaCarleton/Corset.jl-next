# runic: off
"""Fixture of `unwritten-element`: reads of elements no write covers, and partly written filled arrays."""
module UnwrittenElementPositive

function doubled(x::Vector{Float64})
    y = similar(x)
    y[1] = 2x[1]
    return sum(y)
end

second_name(n::Int) = (names = Vector{String}(undef, n); names[1] = "a"; names[2])

total(x::Vector{Float64}) = sum(similar(x))

# Write in branch can cover read.
maybe_set(flag::Bool) = (a = Vector{Float64}(undef, 1); flag && (a[1] = 1.0); a[1])

# Fill value can be data: `possible`.
half_filled() = (a = zeros(4); a[1] = 1.0; a[2] = 2.0; sum(a))

sorted_names() = (a = Vector{String}(undef, 2); sort!(a); a)

maybe_name(flag::Bool) = (a = Vector{String}(undef, 1); flag ? a[1] : "none")

# View checks bounds of index array: reads every index.
picked(values::Vector{Float64}) = (indices = Vector{Int}(undef, 2); sum(view(values, indices)))

end
