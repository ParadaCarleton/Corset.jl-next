# ==> src/OverspecifiedTypePositive.jl
# runic: off
"""Package whose functions annotate narrower types than their code needs."""
module OverspecifiedTypePositive

export scale, area, total, middle, weighted, present, rows, absolute, Point, power, code, rounded, forwarded, halve, third, quarter, doubled
public counted, sizes, members, mean

"""Scaled copy of values."""
scale(values::AbstractVector{<:Real}, factor::Real) = values .* factor

"""Area of circle."""
area(radius::Real) = pi * radius^2

"""Sum of counts."""
total(counts::AbstractDict{String, <:Integer}) = sum(values(counts))

"""Midpoint of two integers."""
middle(low::Integer, high::Real) = (low + high) / 2

"""Half sum of pair, times weight."""
weighted(pair::NTuple{2, Real}; weight::Real = 1.0f0) = weight * sum(pair) / 2

"""Whether value is present."""
present(value::Union{Nothing, Real}) = value !== nothing

"""Row count of grid."""
rows(grid::AbstractMatrix{<:Real}) = size(grid, 1)

"""Sum of absolute values."""
absolute(values::AbstractVector{<:Real}) = sum(abs, values)

"""Count plus start; two methods, one report per annotation."""
counted(items::AbstractVector{<:Integer}, start::Integer = 0) = start + length(items)

"""Point in plane; inner constructor takes only `Float64`."""
struct Point
    x::Float64
    y::Float64
    Point(x::Real, y::Real) = new(x, y)
end

"""Member count of vector or set."""
members(collection::Union{AbstractVector, AbstractSet}) = length(collection)

"""Mean of values with float elements."""
mean(values::AbstractVector{<:Real}) = sum(values) / length(values)

"""Power of base; widened method would overlap `Integer` method, so call `power(2, 3)` becomes ambiguous."""
power(base::Float64, exponent::Int) = base^exponent
power(base::Integer, exponent) = base^exponent

"""Codes of byte and word; both widen to `Integer`, so later method would replace earlier one."""
code(value::Int8) = 1
code(value::Int) = 2

"""Rounded value; widened methods nest, `Integer` inside `Real`, so dispatch keeps both."""
rounded(value::Real) = round(Int, value)
rounded(value::Integer) = value

"""Length of values; private helper takes only `Vector{Float64}`, so public function does too."""
forwarded(values) = forwarded_length(values)
forwarded_length(values::AbstractVector{<:Real}) = length(values)

"""Private helper."""
helper(x::Real) = 2x

"""Private struct; its constructor takes only `Float64`."""
struct Hidden
    value::Float64
    Hidden(value::Real) = new(value)
end

"""Lengths of named groups."""
sizes(groups::AbstractDict{Symbol, <:AbstractVector{<:Real}}) = Dict(name => length(group) for (name, group) in groups)

"""Half of float, else zero; widened private `halved` would change `applicable` answer, so fix is manual."""
halve(x) = Base.applicable(halved, x) ? halved(x) : 0
halved(x::Float64) = x / 2

"""Third of float, else zero; widened private `thirded` would throw no `MethodError` to catch, so fix is manual."""
function third(x)
    try
        return thirded(x)
    catch error
        error isa MethodError || rethrow()
        return 0
    end
end
thirded(x::Float64) = x / 3

"""Quarter of float, else zero; bare `catch` swallows `MethodError` from private `quartered`, so fix is manual."""
function quarter(x)
    try
        return quartered(x)
    catch
        return 0
    end
end
quartered(x::Float64) = x / 4

"""Callable that scales floats by `factor`."""
struct Scaler
    factor::Real
end
(scaler::Scaler)(x::Float64) = scaler.factor * x
const doubler = Scaler(2)

"""Double of float, else zero; widened call method of `Scaler` would change `applicable` answer, so fix is manual."""
doubled(x) = applicable(doubler, x) ? doubler(x) : 0


"""Appends one; resized argument widens container and element type."""
appended(items::AbstractVector{<:Real}) = push!(items, 1.0)

"""Appends one through bounded element type: argument type is `UnionAll`, widened as whole."""
appended_bound(items::AbstractVector{<:Real}) = push!(items, 1.0)

"""Appends zero to each row; rows and outer container widen."""
function padded(rows::AbstractVector{<:AbstractVector{<:Real}})
    for row in rows
        push!(row, 0.0)
    end
    return rows
end

"""Tags float vector after append; widened method nests integer method."""
tagged(items::AbstractVector{<:Real}) = (push!(items, 1.0); :float)
tagged(items::AbstractVector{<:Integer}) = :integer

"""Registers name; inserted dictionary widens."""
register(table::AbstractDict{Symbol, Any}, name::Symbol) = (table[name] = nothing; table)

"""Pushes values through closure that captures resized vector."""
collect_into(items::AbstractVector{Any}, values) = foreach(value -> push!(items, value), values)

"""Forwards resized vector to package function."""
forward_into(items::AbstractVector{Any}) = collect_into(items, (1, 2))

"""Float vector under alias name; fix keeps alias, which overlaps abstract method, so fixes are manual."""
const FloatValues = Vector{Float64}
aliased(values::FloatValues, factor::Float64) = factor
aliased(values::AbstractVector{Float64}, factor::Int) = factor

"""Shapes values; fixed signature keeps dotted names, literals, `where` and method variables."""
shaped(cell::Base.RefValue{<:Real}, mode::Tuple{Val{:fast}, AbstractArray{<:Real, 2}}, pair::Tuple{Real, T}, table::AbstractDict{<:Real, Ref{U} where {U <: Integer}}) where {T} = pair

"""Picks first; call inside annotation leaves fixed signature unknown, so both fixes are manual."""
picked(pair::Tuple{Float64, Val{sum((1, 1))}}) = pair[1]
picked(pair::Tuple{Int, Val{2}}) = pair[1]

"""Module without `AbstractVector`: widened annotation names no binding there, so fix is manual."""
baremodule Bare
import Base: Vector, Int, first
"""First item."""
head(items::Vector{Int}) = first(items)
end

TagType = Int
"""Tags pair; `TagType` can change after definition, so fixed signature is unknown and both fixes are manual."""
tupled(pair::Tuple{TagType, Float64}) = :tagged
tupled(pair::Tuple{Signed, Int}) = :signed

"""Scales count; `Float64` fix makes `scaled(1, "x", 1)` ambiguous, with or without `Int` fix, so both are manual."""
scaled(count::Integer, label::String, factor::Float64) = count
scaled(count::Signed, label::String, factor::Int) = count

"""Steps count; `step` and `factor` fixes together make `stepped(1, 0x01, 1)` ambiguous, so both are manual."""
stepped(count::Integer, step::Int, factor::Float64) = count
stepped(count::Signed, step::UInt8, factor::Signed) = count

"""First of six; two methods have 12 fixes, too many combinations to check, so each fix is manual."""
sixth(a::Int, b::Int, c::Int, d::Int, e::Int, f::Int) = a
sixth(a::Float64, b::Float64, c::Float64, d::Float64, e::Float64, f::Float64) = a

"""Module whose `Real` names no type: fixed bound is unknown, so fix is manual."""
module NoReal
const Real = 1
"""First item."""
first_real(items::Vector{Float64}) = first(items)
end

"""Module whose `Integer` names no type: fixed annotation would break definition, so fixes are manual."""
module NoInteger
const Integer = 1
"""Same count."""
same(count::Int) = count
"""Keyword count."""
counted(; count::Int = 1) = count
end

"""Module whose `AbstractVector` names no type: Julia rejects fixed annotation, so fix is manual."""
module NoVector
const AbstractVector = 1
"""First item."""
first_item(items::Vector{Float64}) = first(items)
end

end
