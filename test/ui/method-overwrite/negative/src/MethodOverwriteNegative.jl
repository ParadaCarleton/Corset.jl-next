# runic: off
module MethodOverwriteNegative

area(side; scale = 1, units = :m) = scale * side^2

perimeter(side::Float64) = 4side
perimeter(side::Int) = 4side

if false
    perimeter(side::Float64) = 0.0
end

label(count::Integer) = "items"
label(count::Int) = count == 1 ? "item" : "items"

end
