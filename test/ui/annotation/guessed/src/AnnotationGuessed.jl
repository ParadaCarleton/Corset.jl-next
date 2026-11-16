# runic: off
module AnnotationGuessed

# Package calls pass `Float64` and `Int`, so arguments and result take `Real`.
area(width, height) = width * height
total_area(side::Float64, count::Int)::Float64 = area(side, count) + area(side, side)

# Arguments typed: result guess from stand-in inference is `likely`.
halved(x::Real) = x / 2

# Array argument takes element family.
summed(values) = sum(values)
mean_of(xs::AbstractVector{<:Real})::Real = summed(xs) / length(xs)

# Struct argument takes nearest abstract supertype.
abstract type Shape end
struct Circle <: Shape
    radius::Float64
end
radius_of(shape) = shape.radius
described(circle::Circle)::Float64 = radius_of(circle)

# Default value is evidence; method for omitted default calls with it.
scaled(x::Real, factor = 2) = x * factor

# Keyword: result seen with default only, so guess is `breaking`.
scaled_by(x::Real; factor::Real = 2) = x * factor
# Branch on type can return what no stand-in saw, so result guess is `breaking`.
sized(x::Real) = x isa BigFloat ? "big" : 64
# `Number` stand-ins model no `Complex`, so result guess is `breaking`.
doubled_number(x::Number) = 2x
# Signatures over limit: results miss some argument types, so guess is `breaking`.
summed4(a::Real, b::Real, c::Real, d::Real) = a + b + c + d
# Explicit `::Any` result infers `Any`: no family, no guess.
passed(x::Any) = x
uses_all(x::Float64)::Real = scaled_by(x) + summed4(x, x, x, x) + passed(1) + doubled_number(x) + length(string(sized(x)))

# Argument type has no family name in scope; result guess stays `breaking`.
counted(items) = length(collect(items))
pair_count(xs::Vector{Int}, ys::Vector{Int})::Int = counted(zip(xs, ys))

# Default value is only evidence; other argument stays manual.
shifted(x, by = 0.5) = x + by

# No package call reaches it: no evidence.
joined(a, b) = string(a, b)

end
