# runic: off
"""Package whose iterators declare element type, and iterators rule leaves to subtypes."""
module IteratorTraitsNegative

"""Count down from start to one."""
struct Countdown
    start::Int
end

Base.iterate(countdown::Countdown, count::Int = countdown.start) = count < 1 ? nothing : (count, count - 1)
Base.length(countdown::Countdown) = countdown.start
Base.eltype(::Type{Countdown}) = Int

"""Items once each."""
struct Cycle{T}
    items::Vector{T}
end

Base.iterate(cycle::Cycle, index::Int = 1) = index > length(cycle.items) ? nothing : (cycle.items[index], index + 1)
Base.length(cycle::Cycle) = length(cycle.items)
Base.eltype(::Type{Cycle{T}}) where {T} = T

"""Lines of text; `collect` finds element type from values."""
struct Lines
    text::String
end

Base.iterate(lines::Lines, state = nothing) = iterate(eachsplit(lines.text, '\n'), something(state, ()))
Base.IteratorSize(::Type{Lines}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{Lines}) = Base.EltypeUnknown()

"""Decimal digits; `eltype` on value."""
struct Digits
    number::Int
end

Base.iterate(number::Digits, rest::Int = number.number) = rest == 0 ? nothing : (rest % 10, rest ÷ 10)
Base.length(number::Digits) = ndigits(number.number)
Base.eltype(::Digits) = Int

"""Vector `[1, 2]`; `AbstractArray` gives element type."""
struct Two <: AbstractVector{Int} end

Base.size(::Two) = (2,)
Base.getindex(::Two, index::Int) = index
Base.iterate(two::Two, index::Int = 1) = index > 2 ? nothing : (index, index + 1)

"""Stream interface; each subtype defines `eltype`."""
abstract type Stream end

Base.iterate(stream::Stream, state = nothing) = nothing

"""Ends of segment, iterated through union."""
struct Left end
struct Right end

Base.iterate(::Union{Left, Right}, state = nothing) = nothing

"""Steps; own `iterate` function, separate from `Base.iterate`."""
struct Steps end

iterate(steps::Steps) = nothing

# Iteration of Base type and method without arguments; rule skips both.
Base.iterate(some::Some{Countdown}, state = nothing) = nothing
Base.iterate() = nothing

end
