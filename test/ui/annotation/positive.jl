# runic: off
area(width, height) = width * height

function scale(points::Vector{Float64}, factor; center = 0.0, weights...)::Vector{Float64}
    return (points .- center) .* factor
end

first_pair((left, right)) = left

Base.show(io::IO, shape::Shape) = print(io, "shape")

limit(x::T, bound::T = zero(T)) where {T <: Real} = min(x, bound)

struct Box
    side::Float64
    Box(side) = new(side)
end
