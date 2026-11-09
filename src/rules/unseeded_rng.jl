# The `unseeded-rng` rule: a test that draws random numbers pins its seed, so a failure replays.

"""The functions that draw or shuffle with a random number generator, global when none is passed first."""
const RANDOM_DRAWS = (:rand, :randn, :rand!, :randn!, :randexp, :randexp!, :sample, :sample!, :shuffle, :shuffle!, :randperm, :randcycle, :bitrand)

"""The generator constructors that seed from the system when called with no argument."""
const SYSTEM_SEEDED = (:Xoshiro, :MersenneTwister, :default_rng, :RandomDevice, :TaskLocalRNG, :StableRNG, :Random123)

"""Whether parsed argument `node` is a generator: a name containing `rng` or `random`, or a constructor call."""
is_generator(node::Symbol)::Bool = occursin(r"rng|random|generator"i, string(node))
is_generator(node::Expr)::Bool = callee(node) in SYSTEM_SEEDED || (node.head === :. && is_generator(last(node.args)))
is_generator(node::QuoteNode)::Bool = is_generator(node.value)
is_generator(::Any)::Bool = false

"""Whether parsed expression `node` seeds the global generator: a call of `seed!`."""
seeds_global(node::Expr)::Bool = callee(node) === :seed!

"""Whether `path`, relative to `root`, sits in a `test` or `tests` directory."""
in_tests(root::AbstractString, path::AbstractString)::Bool = any(in(("test", "tests")), splitpath(dirname(relpath(path, root))))

"""
Draws of random numbers in a test file, keyed by file and the function or testset they sit in: a draw from the
global generator in a file that never calls `seed!`, and a generator built with no seed (`Xoshiro()`).
"""
function unseeded_rngs(root::AbstractString, source::Source)::Vector{Site}
    (; path, name, located) = source
    if !in_tests(root, path)
        return Site[]
    end
    seeded = any(item -> seeds_global(item.node), located)
    return [
        Site("$name $(item.enclosing)", path, item.line, detail)
            for item in located
            for detail in [unseeded_detail(item.node, seeded)] if !isempty(detail)
    ]
end

"""Why call `node` draws without a pinned seed, or the empty string when it does not."""
function unseeded_detail(node::Expr, seeded::Bool)::String
    if node.head === :call && callee(node) in SYSTEM_SEEDED && isempty(call_arguments(node))
        return "builds a generator from the system; pass a seed"
    end
    if node.head === :call && callee(node) in RANDOM_DRAWS && !seeded && !is_generator(get(call_arguments(node), 1, nothing))
        return "draws from the global generator, which no `Random.seed!` call in this file pins"
    end
    return ""
end
