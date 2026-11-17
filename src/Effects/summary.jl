"""Place of access to `origin` that caller can see; `nothing` for fresh object (its accesses stay local)."""
function access_place(origin::Origin.Type)::Union{Nothing, Place.Type}
    return @match origin begin
        Origin.Caller(place) => place
        Origin.Unknown() => Place.At(Root.Elsewhere(), Step.Type[])
        Origin.Allocation(_) => nothing
    end
end

"""Accesses of `table` on places caller can see, strongest effect per place."""
function exported_effects(table::OriginAccesses)::Accesses
    found = Accesses()
    for ((origin, below), effect) in table
        place = access_place(origin)
        isnothing(place) && continue
        key = (place, below)
        found[key] = haskey(found, key) ? stronger(found[key], effect) : effect
    end
    return found
end

"""Node of exported graph for `origin`."""
node_of(origin::Origin.Type)::Node.Type = @match origin begin
    Origin.Caller(place) => Node.Placed(place)
    Origin.Allocation(index) => Node.Fresh(index)
    Origin.Unknown() => Node.Outside()
end

"""Nodes of `targets`."""
nodes_of(targets::Targets)::Nodes = Nodes(node_of(origin) => doubt for (origin, doubt) in targets)

"""
Fresh objects caller can reach after call: from result, from stores into caller objects and globals, and from slots of
fresh objects so reached.
"""
function escaping(flow::Flow)::Set{Origin.Type}
    pending = collect(keys(flow.result))
    for holder in union(keys(flow.heap), keys(flow.backing), keys(flow.spread))
        fresh_origin(holder) || foreach(targets -> append!(pending, keys(targets)), contents(flow, holder))
    end
    foreach(targets -> append!(pending, keys(targets)), values(flow.bound))
    found = Set{Origin.Type}()
    while !isempty(pending)
        origin = pop!(pending)
        fresh_origin(origin) && !(origin in found) || continue
        push!(found, origin)
        foreach(targets -> append!(pending, keys(targets)), contents(flow, origin))
    end
    return found
end

"""Summary of instance from `flow` at fixpoint: caller-visible accesses, stores of exported objects, and result."""
function summarize(flow::Flow)::Summary
    exported = escaping(flow)
    shown(origin::Origin.Type)::Bool = !fresh_origin(origin) || origin in exported
    edges = Dict((node_of(holder), step) => nodes_of(targets) for (holder, slots) in flow.heap if shown(holder) for (step, targets) in slots if !isempty(targets))
    backing = Dict(node_of(holder) => nodes_of(targets) for (holder, targets) in flow.backing if shown(holder) && !isempty(targets))
    spread = Dict(node_of(holder) => nodes_of(targets) for (holder, targets) in flow.spread if shown(holder) && !isempty(targets))
    bound = Dict(binding => nodes_of(targets) for (binding, targets) in flow.bound if !isempty(targets))
    return Summary(exported_effects(flow.writes), exported_effects(flow.reads), edges, backing, spread, bound, nodes_of(flow.result), length(exported), flow.closed_world)
end
