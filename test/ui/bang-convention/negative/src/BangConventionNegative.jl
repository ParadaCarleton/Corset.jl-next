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

# Base IO function promises write.
mutable struct Resource
    open::Bool
end
Base.close(resource::Resource) = (resource.open = false; nothing)

# `__init__` sets state once, at load.
const WORKERS = Ref(1)
__init__() = (WORKERS[] = Threads.nthreads(); nothing)
workers() = WORKERS[]

# Hook returns `nothing`; method with nothing to change returns argument.
update!(state::Vector{Int}) = nothing
reset!(point::Tuple{Float64}) = point

# `!!` mutates when possible, else returns new value.
grow!!(items::Vector{Int}) = vcat(items, 0)

# Constructor and callable object cannot take `!`.
struct Log
    lines::Vector{String}
end
Log(line::String, lines::Vector{String}) = (push!(lines, line); Log(lines))
(log::Log)(line::String) = (push!(log.lines, line); nothing)

end
