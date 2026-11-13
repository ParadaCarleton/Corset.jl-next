# runic: off
module ShadowedBaseNegative

import Base: length

struct Square
    side::Float64
end

Base.show(io::IO, square::Square) = print(io, "Square(", square.side, ")")
length(square::Square) = 4
Base.:+(left::Square, right::Square) = Square(left.side + right.side)
perimeter(square::Square) = 4 * square.side
print_matrix_row(rows) = rows

end
