# runic: off
module HiddenInputPositive

using Random: Random, AbstractRNG

const SCALE = Ref(1.0)

set_scale!(scale::Float64) = (SCALE[] = scale; nothing)

scaled(x::Float64) = SCALE[] * x

noisy(x::Float64) = x + randn()

# Callee draws from default RNG and gets finding.
noisy_twice(x::Float64) = noisy(noisy(x))

jitter(rng::AbstractRNG, x::Float64) = x + randn(rng)
jitter(x::Float64) = jitter(Random.default_rng(), x)

# Method takes RNG but draws without it.
ignored(rng::AbstractRNG) = rand()

# RNG method takes other argument types, so caller of `pick(1)` cannot pass RNG.
pick(rng::AbstractRNG, x::String) = rand(rng)
pick(x::Int) = rand()

# RNG method ignores its RNG too, so it gives caller of `twin(1)` no control.
twin(rng::AbstractRNG, x::Int) = rand()
twin(x::Int) = rand()

# Both fields hold one object: write through one field changes read through other.
const SHARED = Ref(1)
const ALIASED = (stable = SHARED, changing = SHARED)
bump_aliased!() = (ALIASED.changing[] += 1; nothing)
aliased() = ALIASED.stable[]

# Convenience method chooses default RNG; its caller hides that input.
function jittered(points::Vector{Float64})
    return [jitter(point) for point in points]
end

end
