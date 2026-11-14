now_year() = Dates.year(Dates.now())
label(value::Float64) = @sprintf("%.2f", value)

# Local, key and field named like imports are no uses.
function scaled()
    norm = 2.0
    return norm * 3
end
const WEIGHTS = (; dot = 1.0)
const UNIT_WEIGHT = WEIGHTS.dot
struct Product
    dot::Float64
end
