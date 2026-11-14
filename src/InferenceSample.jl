"""
Package code shapes precompile workload runs `inference` stage on: arithmetic, loops, indexing, reductions,
broadcasting, matrices, structs and function arguments. Base callees on stand-in types then load from package image.
"""
module InferenceSample

"""Disk with radius of any real type."""
struct Disk{T <: Real}
    radius::T
end

"""Area of `disk`."""
area(disk::Disk)::Real = pi * disk.radius^2

"""Arithmetic, comparison, rounding and elementary functions on `x` and `y`."""
function arithmetic(x::Real, y::Real)::Real
    total = x + y - x * y / (abs(x) + one(x))
    total += sqrt(abs(y)) + exp(-abs(x)) + log1p(abs(y)) + sin(x) * cos(y) + atan(y, x)
    return max(min(total, x), y) + round(total) + floor(x) + x^2 + (x < y ? zero(x) : x) + hypot(x, y)
end

"""Integer division, remainder, shifts and parity on `n` and `k`."""
function integers(n::Integer, k::Integer)::Integer
    return div(n, max(k, one(k))) + rem(n, 3) + n * k + abs(n - k) + (iseven(n) ? n >> 1 : n << 1) + mod(n, 7)
end

"""Sum, extremes and length of `values`, by loop and by reduction."""
function reductions(values::AbstractVector{<:Real})::Real
    acc = zero(eltype(values))
    for index in eachindex(values)
        acc += values[index]
    end
    for value in values
        acc = max(acc, value)
    end
    return acc + sum(values) + maximum(values) + minimum(values) + length(values) + sum(abs2, values) + prod(values)
end

"""Scaled, absolute, reversed and sorted copies of `values`."""
function transforms(values::AbstractVector{<:Real}, factor::Real)::AbstractVector
    scaled = values .* factor .+ one(factor)
    copied = similar(values)
    copied .= abs.(values)
    copied[begin] = first(values)
    return vcat(map(abs2, scaled), copied, reverse(values), sort(values), cumsum(values))
end

"""Sum of `grid` entries by loop, by column sums and by corner."""
function matrices(grid::AbstractMatrix{<:Real})::Real
    rows, columns = size(grid)
    total = zero(eltype(grid))
    for column in 1:columns, row in 1:rows
        total += grid[row, column]
    end
    return total + sum(grid; dims = 1)[1] + grid[1, end] + sum(view(grid, :, 1))
end

"""`f` applied to `x`, and to `x` doubled."""
apply(f::Function, x::Real)::Real = f(x) + f(2x)

"""Text with `x` rounded to two digits."""
describe(x::Real)::String = string("value: ", round(x; digits = 2), " of ", typeof(x))

end
