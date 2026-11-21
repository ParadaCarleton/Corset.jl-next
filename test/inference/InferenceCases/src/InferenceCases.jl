# runic: off
module InferenceCases

include("macros.jl")

# Quoted block carries this line, so expansion statements point here.
macro add_one(ex)
    return quote
        $(esc(ex)) + 1
    end
end

"""Defines function and evaluator with two more leading arguments at its line, as DynamicPPL `@model` does."""
macro modeled(definition)
    call, body = definition.args
    evaluator = Expr(:function, Expr(:call, call.args[1], :model, :info, call.args[2:end]...), body)
    return esc(Expr(:block, definition, evaluator))
end

@modeled function evaluated(x::Real)
    return x
end

abstract type Shape end
struct Circle{T <: Real} <: Shape
    radius::T
end
area(shape::Shape) = pi * shape.radius^2
a::Real ⊕ b::Real = a + b
(shape::Circle)(x::Real) = shape.radius * x
scale(x::Real, factor::Integer) = x * factor
broken(x::Real) = x + nothing
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
first_value(values) = values[1]
opening(values::AbstractVector) = first_value(values)
viewing(values::AbstractMatrix) = first_value(view(values, :, 1))
# `collect` of open stand-in gives `Vector` family without stand-in: call reaches no unit, guess still reads it.
tallied(collected) = length(collected)
collecting(values::AbstractVector) = tallied(collect(values))
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
struct Wrap{T}
    v::T
end
function declared end
const unit = Circle(1.0)
spread(x::Real) = max(x, ("a",)...)
boxed(x::Real) = Circle(x; tag = 1)
rewrapped(w::Wrap{T}) where {T} = Wrap{T}(w.v; tag = 1)
called_unit(x::Real) = unit(x, x)
odd(x::UInt8) = x
oddly(x::Integer) = odd(x)
single(x::Float32) = x / 2
halved(x::AbstractFloat) = single(x)
checked(x::Real) = x > 0 ? x : error("negative")
function padded(x::Real, y = 2)
    return x + y
end
include("uses.jl")
include("callees.jl")
include("callers.jl")
# Serializer has no method for enum value.
@enum Mode fast slow
# Discarded calls: one per line maps; two of one callee on one line map to neither.
function dropped(x::Real)
    abs(x)
    abs(x) + 1; abs(x) + 1
    return x
end
# Qualified callee lowers to `getproperty` statement.
function dropped_qualified(x::Real)
    Base.abs(x)
    return x
end

end
