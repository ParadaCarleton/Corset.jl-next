"""
Package code precompile workload runs package stages, rules and `inference` stage on: arithmetic, loops, indexing,
reductions, broadcasting, matrices, structs, iterator and array interfaces, and function arguments.
"""
module PackageSample

"""Disk with radius of any real type."""
struct Disk{T <: Real}
    radius::T
end

"""Area of `disk`."""
area(disk::Disk)::Real = pi * disk.radius^2

"""Arithmetic, comparison, rounding and elementary functions on `left` and `right`."""
function arithmetic(left::Real, right::Real)::Real
    total = left + right - left * right / (abs(left) + one(left))
    total += sqrt(abs(right)) + exp(-abs(left)) + log1p(abs(right)) + sin(left) * cos(right) + atan(right, left)
    return max(min(total, left), right) + round(total) + floor(left) + left^2 + (left < right ? zero(left) : left) + hypot(left, right)
end

"""Integer division, remainder, shifts and parity on `dividend` and `divisor`."""
function integers(dividend::Integer, divisor::Integer)::Integer
    quotient = div(dividend, max(divisor, one(divisor)))
    return quotient + rem(dividend, 3) + dividend * divisor + abs(dividend - divisor) + (iseven(dividend) ? dividend >> 1 : dividend << 1) + mod(dividend, 7)
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
    total = zero(eltype(grid))
    for column in axes(grid, 2), row in axes(grid, 1)
        total += grid[row, column]
    end
    return total + first(sum(grid; dims = 1)) + grid[begin, end] + sum(view(grid, :, firstindex(grid, 2)))
end

"""Countdown from `start` to one."""
struct Countdown
    start::Int
end

Base.iterate(countdown::Countdown, state::Int = countdown.start)::Union{Nothing, Tuple{Int, Int}} = state <= 0 ? nothing : (state, state - 1)
Base.length(countdown::Countdown)::Int = countdown.start
Base.eltype(::Type{Countdown})::Type{Int} = Int

"""Vector of `length` ones."""
struct Ones <: AbstractVector{Float64}
    length::Int
end

Base.size(ones::Ones)::Tuple{Int} = (ones.length,)
Base.getindex(ones::Ones, index::Int)::Float64 = (checkbounds(ones, index); 1.0)

"""`transform` applied to `number`, and to `number` doubled."""
apply(transform::Function, number::Real)::Real = transform(number) + transform(2number)

"""
Literal of each value type source can spell. Source mapping looks up literals by value, and that lookup compiles once
per value type.
"""
literals()::Tuple = (
    1, 2.5, 2.5f0, true, 'c', "text", 0x01, 0x0001, 0x00000001, 0x0000000000000001, 0x00000000000000000000000000000001,
    170141183460469231731687303715884105727, 1701411834604692317316873037158841057270,
)

"""Text with `number` rounded to two digits."""
describe(number::Real)::String = string("value: ", round(number; digits = 2), " of ", typeof(number))

end
