# runic: off
module NeverSucceedsPositive

struct Point
    x::Float64
end

norm2(point::Point) = point.x^2 + point.y^2

label(text::AbstractString) = uppercase(text)
describe(count::Integer) = label(count)

half(count::UInt64) = count >> 1
halve(count::Integer) = half(count)
# Failure inside `halve` reports there only.
quarter(count::Integer) = halve(halve(count))

# Curly callee: `Vector{T}(n)` needs `undef` since Julia 1.0. Its span once went unmatched.
buffer(count::Int) = Vector{Float64}(count)

# Default value fails declared type, so call that omits it throws.
function scaled(count::Integer, factor::Integer = 1.5)
    return count * factor
end

# Cycle without base case reports once, at first method; caller of cycle only inherits it.
variance(x::Real) = deviation(x)^2
deviation(x::Real) = sqrt(variance(x))
spread(x::Real) = deviation(x) + 1

# Loop without exit.
function settle(count::Int)
    while true
        count += 1
    end
    return count
end

end
