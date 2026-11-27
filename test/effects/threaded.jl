# Threaded solve, run by `effects.jl` in child process with several threads: test process may run one thread.
using Corset.Effects.Summaries: after_successors, start_run, solve!, dispatch, held_summary, same, Variant
using Random: Xoshiro

"""Graph of `size` vertices from `rng`: each vertex calls earlier vertex with chance `density`."""
ordered_graph(rng::Xoshiro, size::Integer, density::Real)::Vector{Vector{Int}} = [[target for target in 1:(vertex - 1) if rand(rng) < density] for vertex in 1:size]

"""Whether `after_successors` on all threads runs each vertex of `successors` once, after each successor ended."""
function keeps_order(successors::AbstractVector{<:AbstractVector{Int}})::Bool
    runs, clock = [Threads.Atomic{Int}(0) for _ in successors], Threads.Atomic{Int}(0)
    starts, ends = zeros(Int, length(successors)), zeros(Int, length(successors))
    after_successors(successors) do vertex
        Threads.atomic_add!(runs[vertex], 1)
        starts[vertex] = Threads.atomic_add!(clock, 1)
        # Yield, so other workers take vertices meanwhile.
        yield()
        ends[vertex] = Threads.atomic_add!(clock, 1)
    end
    return all(count -> count[] == 1, runs) && all(starts[vertex] > ends[target] for vertex in eachindex(successors) for target in successors[vertex])
end

"""Root variants of Base calls with deep call graphs, in world of `run`."""
roots(world::UInt)::Vector{Variant} = [(only(something(dispatch(Any[typeof(callee), types...], world, 1))), Pair{Int, Any}[]) for (callee, types) in ((sort!, [Vector{Int}]), (setindex!, [Dict{String, Int}, Int, String]), (join, [Vector{String}, String]))]

"""Whether solve on one worker and on all threads gives same summary to each variant."""
function same_summaries()::Bool
    alone, threaded = start_run(nothing, Module[]), start_run(nothing, Module[])
    solve!(alone, roots(alone.world); workers = 1)
    solve!(threaded, roots(threaded.world))
    return keys(alone.slots) == keys(threaded.slots) && all(same(held_summary(alone.slots, variant), held_summary(threaded.slots, variant)) for variant in keys(alone.slots))
end

Threads.nthreads(:default) > 1 || error("threaded solve test needs several threads")
rng = Xoshiro(1)
all(keeps_order(ordered_graph(rng, rand(rng, 1:60), rand(rng))) for _ in 1:300) || error("schedule broke call order")
same_summaries() || error("threaded solve changed summaries")
print("threaded solve ok")
