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

# Writer changes other field: field reader sees constant state.
const DATA = (stable = Ref(1), changing = Ref(1))
bump_changing!() = (DATA.changing[] += 1; nothing)
stable() = DATA.stable[]

# Tuple positions settle cells: writer of first cell leaves second cell reader alone.
const PAIR = (Ref(1), Ref(2))
set_first!(x::Int) = (PAIR[1][] = x; nothing)
second_of_pair() = PAIR[2][]

# Binding is not constant but holds cell no method writes.
const QUIET = Ref(0)
current_quiet::Base.RefValue{Int} = QUIET
quiet_now() = current_quiet[]

# Write to binding can rebind it, so it names no object; equal number in other cell is no shared object.
level_count::Int = 0
set_level_count!(count::Int) = (global level_count = count; nothing)
const ZERO_CELL = Ref(0)
zero_cell() = ZERO_CELL[]

# Trailing optional RNG: caller can pass one.
tail_draw(x::Float64, rng::AbstractRNG = Random.default_rng()) = x + randn(rng)

# Keyword RNG: caller can pass one.
keyword_draw(n::Int; rng::AbstractRNG = Random.default_rng()) = rand(rng, n)
scaled_draw(n::Int; scale::Float64 = 1.0, rng::AbstractRNG = Random.default_rng()) = scale * rand(rng, n)

# Sibling draws through open call on its RNG argument.
struct Mix
    means::Vector{Float64}
end
draw(rng::AbstractRNG, mix::Mix) = mix.means[1] + randn(rng)
draw(mix::Mix) = mix.means[1] + randn()

# Default positional arguments define one method per arity: caller of `spread(values)` can call `spread(values, 2.0, rng)`.
pick(::Nothing, values::Vector{Float64}) = rand(values)
pick(rng::AbstractRNG, values::Vector{Float64}) = rand(rng, values)
spread(values::Vector{Float64}, scale::Float64 = 2.0^3, rng::Union{AbstractRNG, Nothing} = nothing) = scale * pick(rng, values)
# Keywords keep shorter methods calling own function: `sample(values)` calls `sample(values, nothing)`.
sample(values::Vector{Float64}, rng::Union{AbstractRNG, Nothing} = nothing; scale::Float64 = 1.0) = scale * pick(rng, values)

end
