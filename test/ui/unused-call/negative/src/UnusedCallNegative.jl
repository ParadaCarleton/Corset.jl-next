# runic: off
module UnusedCallNegative

function check(text::String)
    parse(Int, text)
    return text
end

function grow!(items::Vector{Int}, item::Int)
    push!(items, item)
    return items
end

function report(count::Int)
    println(count)
    return count
end

function draw(count::Int)
    rand()
    return count
end

function keep(count::Int)
    Base.donotdelete(count)
    return count
end

area(radius::Float64) = π * radius^2

# Value assigned to name no code reads: unused variable, not discarded statement.
function squared(level::Float64)
    unread = level * level
    return level
end

# Condition inference folds for one member of union stays condition in source.
halved(value::Union{Nothing, Float64}) = value === nothing ? 0.0 : value / 2

end
