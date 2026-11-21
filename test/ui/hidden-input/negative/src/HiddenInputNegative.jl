# runic: off
module HiddenInputNegative

using Random: Random, AbstractRNG

# Nothing writes table: it stays constant.
const WEIGHTS = [0.5, 0.25, 0.25]
weight(index::Int) = WEIGHTS[index]

# Caller passes RNG; convenience method names default RNG.
jitter(rng::AbstractRNG, x::Float64) = x + randn(rng)
jitter(x::Float64) = jitter(Random.default_rng(), x)

# Convenience caller passes default RNG through argument.
shuffled!(rng::AbstractRNG, items::Vector{Int}) = Random.shuffle!(rng, items)
shuffled!(items::Vector{Int}) = shuffled!(Random.default_rng(), items)

# Method of same function takes RNG first, so caller can pass one.
struct Die
    sides::Int
end
roll(rng::AbstractRNG, die::Die) = rand(rng, 1:die.sides)
roll(die::Die) = rand(1:die.sides)

# Writer reads its own state: `!` tells caller.
const COUNT = Ref(0)
bump!() = (COUNT[] += 1; COUNT[])

# `__init__` sets state once, at load.
const WORKERS = Ref(1)
__init__() = (WORKERS[] = Threads.nthreads(); nothing)
workers() = WORKERS[]

# Cache read: caller cannot see it.
const SQUARES = Dict{Int, Int}()
square(n::Int) = get!(() -> n^2, SQUARES, n)

end
