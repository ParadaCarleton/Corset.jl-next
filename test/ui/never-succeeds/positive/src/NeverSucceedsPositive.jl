# runic: off
module NeverSucceedsPositive

struct Point
    x::Float64
end

norm2(point::Point) = point.x^2 + point.y^2

label(text::AbstractString) = uppercase(text)
describe(count::Integer) = label(count)
# Failure inside `describe` reports there only.
summary(count::Integer) = describe(count) * "!"

half(count::UInt64) = count >> 1
halve(count::Integer) = half(count)

# Default value fails declared type, so call that omits it throws.
function scaled(count::Integer, factor::Integer = 1.5)
    return count * factor
end

end
