# runic: off
module InferenceCases

include("macros.jl")

# Quoted block carries this line, so expansion statements point here.
macro add_one(ex)
    return quote
        $(esc(ex)) + 1
    end
end

abstract type Shape end
struct Circle{T <: Real} <: Shape
    radius::T
end
area(shape::Shape) = pi * shape.radius^2
scale(x::Real, factor::Integer) = x * factor
broken(x::Real) = x + "a"
helper(x) = 2x
caller(x::Real) = helper(x) + 1
caller_too(x::Real) = helper(x) * 2
assigned(x) = x + 1
assigning(x::Real) = (y = assigned(x); y)
radius_of(shape) = shape.radius
measured(shape::Circle) = radius_of(shape)
unreached(x) = x
constant(x::Real) = unreached(1)
joined(x, s) = s
mixed(x::Real, s::AbstractString) = joined(x, s)
twice(x::Real) = abs(x) + abs(-x)
bumped(x::Real) = @add_one(x)
lonely(x) = x
splatted(xs...) = xs
first_of((a, b)) = a
defaulted(x::Real, y = 2) = x + y
ignored(_, x::Real) = x
keyed(x::Real; factor = 2) = x * factor
hk(x; k::Int = 1) = x + k
slurpy(x::Real; options...) = x
nested(x::Real) = abs(abs(x)) + abs(x)
text(s::AbstractString) = s
explicit(x::Any, y::Real) = y
free(x::T) where {T} = x
wide(a::Real, b::Real, c::Real, d::Real) = a + b + c + d
nest(x) = nest((x,))
start(x::Real) = nest(x)
function total(values::AbstractVector{<:Real})
    acc = zero(eltype(values))
    for value in values
        acc += value
    end
    return acc
end
@generated doubled(x::Real) = :(x + x)
@generated refused(x::Real) = error("generator refuses")
for name in (:made,)
    @eval function $name(x::Real)
        y = x + 1
        return y * 2
    end
end
include("uses.jl")

end
