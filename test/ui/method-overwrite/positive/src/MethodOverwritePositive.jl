# runic: off
module MethodOverwritePositive

area(side; scale = 1) = scale * side^2
area(side; units = :m) = side^2

function perimeter(side::Float64)
    return 4 * side
end
perimeter(side::Float64) = 4side

label(count::Int; plural = true) = plural ? "items" : "item"
label(count::Int) = "items"

for name in (:volume,)
    @eval $name(side) = side^3
end
volume(side) = side * side * side

end
