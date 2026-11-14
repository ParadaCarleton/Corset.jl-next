# runic: off
area(width::Real, height::Real)::Real = width * height

ignore(_, ::Int)::Nothing = nothing

describe(item::Any; verbose::Bool = false)::Any = item

configure(name::String; options...)::String = name

limit(x::T, bound::T = zero(T))::T where {T <: Real} = min(x, bound)

function total(values::Vector{Int})::Int
    helper(x) = 2x
    doubled = map(value -> helper(value), values)
    return sum(doubled)
end

handler = function (event)
    return event
end
