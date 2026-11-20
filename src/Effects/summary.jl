"""Place of access to `origin` that caller can see; `nothing` for fresh object (its accesses stay local)."""
function access_place(origin::Origin.Type)::Union{Nothing, Place.Type}
    return @match origin begin
        Origin.Caller(place) => place
        Origin.Unknown() => Place.At(Root.Elsewhere(), Step.Type[])
        Origin.Allocation(_) => nothing
    end
end

"""
Accesses of `table` on places caller can see, strongest effect per place and kind. Memory access takes kind of
audited `method` or of its path in instance with IR `ir` (`place_kind`).
"""
function exported_effects(ir::CC.IRCode, method::Method, table::OriginAccesses)::Accesses
    found = Accesses()
    for ((origin, below, kind), effect) in table
        place = access_place(origin)
        isnothing(place) && continue
        key = (place, below, place_kind(ir, method, place, kind))
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
        fresh_origin(holder) || foreach_content(targets -> append!(pending, keys(targets)), flow, holder)
    end
    foreach(targets -> append!(pending, keys(targets)), values(flow.bound))
    found = Set{Origin.Type}()
    while !isempty(pending)
        origin = pop!(pending)
        fresh_origin(origin) && !(origin in found) || continue
        push!(found, origin)
        foreach_content(targets -> append!(pending, keys(targets)), flow, origin)
    end
    return found
end

"""
Summary of instance of `method` from `flow` at fixpoint, with callee summaries from `callees`: caller-visible accesses,
stores of exported objects, result, and release balance (`balance`).
"""
function summarize(flow::Flow, method::Method, callees::Callees)::Summary
    held, thrown, unguarded = balance(flow, callees)
    exported = escaping(flow)
    shown(origin::Origin.Type)::Bool = !fresh_origin(origin) || origin in exported
    edges = Dict((node_of(holder), step) => nodes_of(targets) for (holder, slots) in flow.heap if shown(holder) for (step, targets) in slots if !isempty(targets))
    backing = Dict(node_of(holder) => nodes_of(targets) for (holder, targets) in flow.backing if shown(holder) && !isempty(targets))
    spread = Dict(node_of(holder) => nodes_of(targets) for (holder, targets) in flow.spread if shown(holder) && !isempty(targets))
    bound = Dict(binding => nodes_of(targets) for (binding, targets) in flow.bound if !isempty(targets))
    # Records hold no fresh object (`deferred`), so they add no escaping object.
    callbacks = Set{Callback}((variant = variant, parameters = map(nodes_of, arguments)) for records in values(flow.callbacks) for (variant, arguments) in records)
    unguarded_nodes = Dict{Tuple{Node.Type, Resource.T}, Unguarded}((node_of(origin), resource) => hold for ((origin, resource), hold) in unguarded)
    return Summary(
        exported_effects(flow.ir, method, flow.writes), exported_effects(flow.ir, method, flow.reads), edges, backing, spread, bound, callbacks, nodes_of(flow.result), length(exported), flow.closed_world, flow.cut,
        exported_holds(held, exported), exported_holds(thrown, exported), unguarded_nodes,
    )
end
