# runic: off
"""Package whose iterators leave element type to Base default."""
module IteratorTraitsPositive

"""Count down from start to one."""
struct Countdown
    start::Int
end

Base.iterate(countdown::Countdown, count::Int = countdown.start) = count < 1 ? nothing : (count, count - 1)
Base.length(countdown::Countdown) = countdown.start

"""Items once each; `eltype` covers only `Cycle{Int}`."""
struct Cycle{T}
    items::Vector{T}
end

Base.iterate(cycle::Cycle, index::Int = 1) = index > length(cycle.items) ? nothing : (cycle.items[index], index + 1)
Base.length(cycle::Cycle) = length(cycle.items)
Base.eltype(::Type{Cycle{Int}}) = Int

"""Sliding window over vector; two `iterate` methods report once."""
struct Window{T}
    items::Vector{T}
    width::Int
end

Base.iterate(window::Window{T}) where {T} = iterate(window, 1)
Base.iterate(window::Window{T}, start::Int) where {T} =
    start + window.width - 1 > length(window.items) ? nothing : (view(window.items, start:(start + window.width - 1)), start + 1)
Base.length(window::Window) = max(0, length(window.items) - window.width + 1)

"""Steps of walk; `iterate` takes it through type variable."""
struct Walk
    steps::Int
end

Base.iterate(walk::W, step::Int = 0) where {W <: Walk} = step >= walk.steps ? nothing : (step, step + 1)
Base.length(walk::Walk) = walk.steps

"""Pages of book; own `HasEltype` trait without `eltype`."""
struct Pages
    count::Int
end

Base.iterate(pages::Pages, page::Int = 1) = page > pages.count ? nothing : (page, page + 1)
Base.length(pages::Pages) = pages.count
Base.IteratorEltype(::Type{Pages}) = Base.HasEltype()

end
