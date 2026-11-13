# runic: off
module ShadowedBasePositive

struct Square
    side::Float64
end

Base.show(io::IO, square::Square) = print(io, "Square(", square.side, ")")

function Base.length(square::Square)
    return 4
end
Base.length(squares::Vector{Square}) = sum(length, squares)

Base.:+(left::Square, right::Square) = Square(left.side + right.side)

first(name::Symbol) = name

Base.last(square::Square; scale = 1) = scale * square.side

for name in (:eltype,)
    @eval $name(::Square) = Float64
end

end
