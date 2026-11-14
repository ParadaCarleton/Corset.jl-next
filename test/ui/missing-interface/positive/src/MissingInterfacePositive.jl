# runic: off
"""Package whose structs miss methods their interfaces require."""
module MissingInterfacePositive

"""Vector of ones; misses `getindex`."""
struct Ones <: AbstractVector{Float64}
    length::Int
end

Base.size(ones::Ones) = (ones.length,)

"""Matrix with linear `getindex` only; default `IndexCartesian` needs two indices."""
struct Scaled <: AbstractMatrix{Float64}
    values::Vector{Float64}
end

Base.size(scaled::Scaled) = (length(scaled.values), length(scaled.values))
Base.getindex(scaled::Scaled, index::Int) = scaled.values[mod1(index, length(scaled.values))]

"""Grid of any rank; misses `size` and `getindex`. Array finding covers its iteration."""
struct Grid{T, N} <: AbstractArray{T, N}
    data::Vector{T}
end

Base.iterate(grid::Grid, index::Int = 1) = index > length(grid.data) ? nothing : (grid.data[index], index + 1)

"""Character repeated; misses `isvalid` and `iterate`."""
struct Repeated <: AbstractString
    char::Char
    count::Int
end

Base.ncodeunits(repeated::Repeated) = repeated.count
Base.codeunit(repeated::Repeated, index::Int) = UInt8(repeated.char)

"""Count down from start; iterates without `length`."""
struct Countdown
    start::Int
end

Base.iterate(countdown::Countdown, count::Int = countdown.start) = count < 1 ? nothing : (count, count - 1)

"""Stream interface; `iterate` on abstract type makes each subtype iterator."""
abstract type Stream end

Base.iterate(stream::Stream, state::Int = 1) = state > 1 ? nothing : (state, state + 1)

"""Single pulse; misses `length`."""
struct Pulse <: Stream end

"""Table of pairs; `AbstractDict` subtype iterates without `length`."""
struct Table <: AbstractDict{Symbol, Int}
    items::Vector{Pair{Symbol, Int}}
end

Base.iterate(table::Table, index::Int = 1) = index > length(table.items) ? nothing : (table.items[index], index + 1)

"""Columns of window; own `HasLength` trait without `length`."""
struct Window
    width::Int
end

Base.iterate(window::Window, column::Int = 1) = column > window.width ? nothing : (column, column + 1)
Base.IteratorSize(::Type{Window}) = Base.HasLength()

"""Cells of square board; `HasShape` trait without `length` or `size`."""
struct Board
    side::Int
end

Base.iterate(board::Board, cell::Int = 1) = cell > board.side^2 ? nothing : (cell, cell + 1)
Base.IteratorSize(::Type{Board}) = Base.HasShape{2}()

end
