# runic: off
module UnusedCallPositive

function cap!(levels::Vector{Float64}, high::Float64)
    for index in eachindex(levels)
        min(levels[index], high)
    end
    return levels
end

struct Point
    x::Float64
    y::Float64
end

function shifted(point::Point, step::Float64)
    point.x + step
    return Point(point.x, point.y + step)
end

function total(counts::Vector{Int})
    sum = 0
    for count in counts
        sum + count
    end
    return sum
end

# Check passes for stand-in array only: other array types can throw.
function first_of(items::AbstractVector)
    Base.require_one_based_indexing(items)
    return items[1]
end

end
