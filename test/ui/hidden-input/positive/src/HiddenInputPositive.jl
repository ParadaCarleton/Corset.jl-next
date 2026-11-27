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

# Two-RNG method draws from its RNG, but one-RNG method ignores own RNG.
ignored_pair(rng::AbstractRNG) = rand()
ignored_pair(left::AbstractRNG, right::AbstractRNG) = rand(left)

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

# Holder now holds `HELD`; code can repoint holder, so write to `HELD` may change read.
const HELD = Ref(1)
const HOLDER = Ref(HELD)
bump_held!() = (HELD[] += 1; nothing)
held() = HOLDER[][]

# Binding is not constant, so only paths compare: same path gives finding, other path `possible` one.
settings = (count = Ref(0), label = Ref(""))
set_count!(count::Int) = (settings.count[] = count; nothing)
current_count() = settings.count[]
current_label() = settings.label[]

# Copy shares cells of `CELLS`: write through copy may change any cell.
const CELLS = [Ref(1), Ref(2)]
bump_copy!() = (cells = copy(CELLS); cells[1][] += 1; nothing)
first_cell() = CELLS[1][]

# Binding is not constant but now holds `SHARED`: write to `SHARED` may change read.
const SHARED = Ref(0)
current_shared::Base.RefValue{Int} = SHARED
bump_shared!() = (SHARED[] += 1; nothing)
shared_now() = current_shared[]

# Method repoints holder: read through holder loads holder that method writes.
const OUTER = Ref(Ref(0))
const INNER = Ref(Ref(1))
repoint!() = (OUTER[] = INNER[]; nothing)
bump_inner!() = (INNER[][] += 1; nothing)
outer_value() = OUTER[][]

# Convenience method chooses default RNG; its caller hides that input.
function jittered(points::Vector{Float64})
    return [jitter(point) for point in points]
end

# Sibling may draw default RNG through dispatch: it reports, and convenience method keeps caller RNG choice.
abstract type Shape end
struct Dot <: Shape end
struct Blob <: Shape end
jiggle(::Dot) = 0.0
jiggle(::Blob) = randn()
jiggle(rng::AbstractRNG, ::Blob) = randn(rng)
function spread(rng::AbstractRNG, shapes::Vector{Shape})
    total = rand(rng)
    for shape in shapes
        total += jiggle(shape)
    end
    return total
end
spread(shapes::Vector{Shape}) = rand() * length(shapes)

# Untyped RNG keyword counts for none: declare `rng::AbstractRNG`.
untyped_draw(n::Int; rng = Random.default_rng()) = rand(rng, n)

# Keyword body never reads RNG keyword: caller RNG cannot reach draw.
unread_keyword(n::Int; rng::AbstractRNG = Random.default_rng()) = rand(n)

# Default positional RNG argument that full method never reads: full method reports it, `gauge(count)` does not.
gauge(count::Int, rng::Union{AbstractRNG, Nothing} = nothing) = rand(count)

# `nothing` in place of RNG, but RNG method never draws from its RNG: caller RNG cannot reach draw.
toss(::Nothing, count::Int) = rand(count)
toss(rng::AbstractRNG, count::Int) = fill(0.5, count)

# Two definitions on one line: `bump(x)` makes no call to `bump(x, rng)`, so caller RNG cannot reach draw.
bump(x::Int) = rand() + x; bump(x::Int, rng::AbstractRNG) = 0.0

end
