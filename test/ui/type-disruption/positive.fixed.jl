# ==> src/TypeDisruptionPositive.jl
# runic: off
module TypeDisruptionPositive

scaled(x::AbstractFloat) = x * oftype(x, 0.5)

function total(xs::AbstractVector{<:Real})
    s = 0
    for x in xs
        s += x
    end
    return s
end

const HALF = 0.5
halved(x::AbstractFloat) = oftype(x, HALF) * x
diagonal(x::AbstractFloat) = sqrt(2) * x
# Float literal spells irrational constant.
area(radius::AbstractFloat) = 3.14159 * radius^2
widened(x::AbstractFloat) = Float64(x) + x
# Abstract element type keeps stored value as is.
function record!(log::Vector{Real}, x::AbstractFloat)
    log[1] = x * oftype(x, 2.0)
    return nothing
end
scaled_all(xs::AbstractVector{<:AbstractFloat}) = xs .* eltype(xs)(0.5)
widened_all(xs::AbstractVector{<:AbstractFloat}) = Float64.(xs)
shifted_all(xs::AbstractVector{<:AbstractFloat}) = xs .* oftype(first(xs), 0.5) .+ eltype(xs)(1.0)
function fill_scaled!(out::Vector{Real}, xs::AbstractVector{<:AbstractFloat})
    out .= xs .* eltype(xs)(0.5)
    return out
end
converted(x::AbstractFloat) = convert(Float64, x)
paired(x::AbstractFloat) = [x, oftype(x, 0.5)]
# Matrix literal lowers to `hvcat` with row lengths first, so span cannot narrow to one element.
grid(x::AbstractFloat) = [x 0.5; 1.0 2.0]
# Fix converts with type parameter, argument or element type; `float` keeps integer input working.
typed_half(x::T) where {T <: AbstractFloat} = x * T(0.5)
# Fix skips type parameter of integer input.
nth_half(n::N, x::T) where {N <: Integer, T <: AbstractFloat} = n * x * T(0.5)
real_half(x::Real) = x * oftype(float(x), 0.5)
real_typed_half(x::T) where {T <: Real} = x * float(T)(0.5)
real_scaled_all(xs::AbstractVector{<:Real}) = xs .* float(eltype(xs))(0.5)
@inline inlined_half(x::AbstractFloat) = x * oftype(x, 0.5)
# Fix stays manual: argument reassigned, product `2.0x`, `@.` dots every call.
function decayed(x::AbstractFloat)
    x = x * 0.9
    return x
end
doubled(x::AbstractFloat) = 2.0x
dotted(xs::AbstractVector{<:AbstractFloat}) = @. xs * 0.5
# Branch on type can pick other code for other input type.
adjusted(x::AbstractFloat) = x isa Float64 ? x : x * oftype(x, 0.5)

end
