# runic: off
module TypeDisruptionPositive

scaled(x::AbstractFloat) = x * 0.5
doubled(n::Integer) = 2n

function total(xs::AbstractVector{<:Real})
    s = 0
    for x in xs
        s += x
    end
    return s
end

const HALF = 0.5
halved(x::AbstractFloat) = HALF * x
diagonal(x::AbstractFloat) = sqrt(2) * x
# Float literal spells irrational constant.
area(radius::AbstractFloat) = 3.14159 * radius^2
widened(x::AbstractFloat) = Float64(x) + x
# Abstract element type keeps stored value as is.
function record!(log::Vector{Real}, x::AbstractFloat)
    log[1] = x * 2.0
    return nothing
end
scaled_all(xs::AbstractVector{<:AbstractFloat}) = xs .* 0.5
widened_all(xs::AbstractVector{<:AbstractFloat}) = Float64.(xs)
shifted_all(xs::AbstractVector{<:AbstractFloat}) = xs .* oftype(first(xs), 0.5) .+ 1.0
function fill_scaled!(out::Vector{Real}, xs::AbstractVector{<:AbstractFloat})
    out .= xs .* 0.5
    return out
end
converted(x::AbstractFloat) = convert(Float64, x)
paired(x::AbstractFloat) = [x, 0.5]
# Matrix literal lowers to `hvcat` with row lengths first, so span cannot narrow to one element.
grid(x::AbstractFloat) = [x 0.5; 1.0 2.0]
# Branch on type can pick other code for other input type.
adjusted(x::AbstractFloat) = x isa Float64 ? x : x * 0.5

end
