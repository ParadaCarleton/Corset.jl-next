# runic: off
module BangConventionNegative

using Random: AbstractRNG

# `!` name tells caller.
normalize!(v::Vector{Float64}) = (v ./= sum(v); v)

# Fresh vector: nothing caller sees changes.
normalized(v::Vector{Float64}) = (w = copy(v); w ./= sum(w); w)

# IO write needs no `!`.
report(io::IO, x::Int) = println(io, x)

# RNG advance needs no `!`.
draw(rng::AbstractRNG) = rand(rng)

# Cache: non-public global that only `square` touches.
const SQUARES = Dict{Int, Int}()
square(n::Int) = get!(() -> n^2, SQUARES, n)

# Base IO function may write its `IO` stream.
mutable struct Sink <: IO
    count::Int
end
Base.write(sink::Sink, byte::UInt8) = (sink.count += 1; 1)

# Name trust lets `lock` write its lock, after callable argument.
mutable struct Gate
    held::Bool
end
Base.lock(f::Function, gate::Gate) = (gate.held = true; f())

# `__init__` sets state once, at load.
const WORKERS = Ref(1)
__init__() = (WORKERS[] = Threads.nthreads(); nothing)
workers() = WORKERS[]

# Hook returns `nothing`; method with nothing to change returns argument.
update!(state::Vector{Int}) = nothing
reset!(point::Tuple{Float64}) = point

# `!!` mutates when possible, else returns new value.
grow!!(items::Vector{Int}) = vcat(items, 0)

# Range index copies: sorting copy writes nothing caller sees.
smallest(x::Vector{Float64}, n::Int) = (head = x[1:n]; sort!(head); head)

# Constructor and callable object cannot take `!`.
struct Log
    lines::Vector{String}
end
Log(line::String, lines::Vector{String}) = (push!(lines, line); Log(lines))
(log::Log)(line::String) = (push!(log.lines, line); nothing)

end
