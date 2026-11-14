# runic: off
"""Package whose structs implement their interfaces."""
module MissingInterfaceNegative

"""Vector of ones."""
struct Ones <: AbstractVector{Float64}
    length::Int
end

Base.size(ones::Ones) = (ones.length,)
Base.getindex(ones::Ones, index::Int) = 1.0

"""Matrix with linear indexing it declares."""
struct Scaled <: AbstractMatrix{Float64}
    values::Vector{Float64}
end

Base.size(scaled::Scaled) = (length(scaled.values), length(scaled.values))
Base.IndexStyle(::Type{<:Scaled}) = IndexLinear()
Base.getindex(scaled::Scaled, index::Int) = scaled.values[mod1(index, length(scaled.values))]

"""Identity matrix with two-index `getindex`."""
struct Identity <: AbstractMatrix{Bool}
    size::Int
end

Base.size(identity::Identity) = (identity.size, identity.size)
Base.getindex(identity::Identity, row::Int, column::Int) = row == column

"""Grid of any rank."""
struct Grid{T, N} <: AbstractArray{T, N}
    data::Array{T, N}
end

Base.size(grid::Grid) = size(grid.data)
Base.getindex(grid::Grid{T, N}, indices::Vararg{Int, N}) where {T, N} = grid.data[indices...]

"""Integers from start to stop; `AbstractUnitRange` gives `size` and `getindex`."""
struct Interval <: AbstractUnitRange{Int}
    start::Int
    stop::Int
end

Base.first(interval::Interval) = interval.start
Base.last(interval::Interval) = interval.stop

"""Field of values; methods on abstract type serve subtypes."""
abstract type Field <: AbstractVector{Float64} end

Base.size(field::Field) = (field.length,)
Base.getindex(field::Field, index::Int) = 0.0

"""Zero field."""
struct Zero <: Field
    length::Int
end

"""Character repeated."""
struct Repeated <: AbstractString
    char::Char
    count::Int
end

Base.ncodeunits(repeated::Repeated) = repeated.count
Base.codeunit(repeated::Repeated, index::Int) = UInt8(repeated.char)
Base.isvalid(repeated::Repeated, index::Int) = 1 <= index <= repeated.count
Base.iterate(repeated::Repeated, index::Int = 1) = index > repeated.count ? nothing : (repeated.char, index + 1)

"""Count down from start."""
struct Countdown
    start::Int
end

Base.iterate(countdown::Countdown, count::Int = countdown.start) = count < 1 ? nothing : (count, count - 1)
Base.length(countdown::Countdown) = countdown.start

"""Lines of text; size unknown."""
struct Lines
    text::String
end

Base.iterate(lines::Lines, state = nothing) = iterate(eachsplit(lines.text, '\n'), something(state, ()))
Base.IteratorSize(::Type{Lines}) = Base.SizeUnknown()

"""Decimal digits; size trait on value."""
struct Digits
    number::Int
end

Base.iterate(number::Digits, rest::Int = number.number) = rest == 0 ? nothing : (rest % 10, rest ÷ 10)
Base.IteratorSize(::Digits) = Base.SizeUnknown()

"""Cells of square board; `HasShape` trait with `length` and `size`."""
struct Board
    side::Int
end

Base.iterate(board::Board, cell::Int = 1) = cell > board.side^2 ? nothing : (cell, cell + 1)
Base.IteratorSize(::Type{Board}) = Base.HasShape{2}()
Base.length(board::Board) = board.side^2
Base.size(board::Board) = (board.side, board.side)

"""Rows; size trait depends on element type, which inference cannot settle."""
struct Rows{T}
    items::Vector{T}
end

Base.iterate(rows::Rows, index::Int = 1) = index > length(rows.items) ? nothing : (rows.items[index], index + 1)
Base.IteratorSize(::Type{Rows{T}}) where {T} = T <: Number ? Base.HasLength() : Base.SizeUnknown()

"""Tokens; size trait throws, so `collect` never calls `length`."""
struct Tokens end

Base.iterate(tokens::Tokens, state = nothing) = nothing
Base.IteratorSize(::Type{Tokens}) = throw(ArgumentError("tokens have no size trait"))

"""Counter; `length` through `Vararg` method covers call on one counter."""
struct Counter
    count::Int
end

Base.iterate(counter::Counter, state::Int = 1) = state > counter.count ? nothing : (state, state + 1)
Base.length(counters::Counter...) = sum(counter.count for counter in counters)

"""Steps; own `iterate` function, separate from `Base.iterate`."""
struct Steps end

iterate(steps::Steps) = nothing

# Method without arguments has no iterated type.
Base.iterate() = nothing

end
