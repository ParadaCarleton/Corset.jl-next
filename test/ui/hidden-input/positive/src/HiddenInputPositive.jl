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

# Convenience method chooses default RNG; its caller hides that input.
function jittered(points::Vector{Float64})
    return [jitter(point) for point in points]
end

end
