"""Place of access to `origin` that caller can see; `nothing` for fresh object (its accesses stay local)."""
function access_place(origin::Origin.Type)::Union{Nothing, Place.Type}
    return @match origin begin
        Origin.Caller(place) => place
        Origin.Unknown() => Place.At(Root.Elsewhere(), NO_STEPS)
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
Whether call statement `index` of `flow` reseeds default RNG: each callee variant in `callees` reseeds before every
normal exit (`Summary`). Task body (`Spawn`) reseeds new task, so it counts out.
"""
function reseed_call!(flow::Flow, callees::Callees, index::Integer)::Bool
    outcome = flow.outcomes[index]
    isnothing(outcome) && return false
    @match something(outcome) begin
        Outcome.Dispatch(_, _) => nothing
        _ => return false
    end
    variants = callees.variants[index]
    isempty(variants) && return false
    for variant in variants
        summary!(callees, variant).rng.seeds || return false
    end
    return true
end

"""
Reseed facts of instance with `flow` at fixpoint, from callee summaries of `callees` (`engine.md`, Task bodies):
whether every normal exit follows reseed (`reseed_call!`), and whether draw (`Flow`) can come before reseed. Reseed
holds at block start when it holds at end of every predecessor; entry block and predecessor 0 (entry edge) carry none.
"""
function seed_facts!(flow::Flow, callees::Callees)::Tuple{Bool, Bool}
    reseed = BitSet(index for index in 1:length(flow.ir.stmts) if reseed_call!(flow, callees, index))
    isempty(reseed) && return false, !isempty(flow.draws)
    blocks = flow.ir.cfg.blocks
    # Must analysis starts from all blocks seeded: values only fall, so loop ends.
    at_end = trues(length(blocks))
    at_start(block::Integer)::Bool = block != 1 && all(predecessor -> predecessor != 0 && at_end[predecessor], blocks[block].preds)
    changed = true
    while changed
        changed = false
        for (block, info) in enumerate(blocks)
            seeded = at_start(block) || any(in(reseed), info.stmts)
            seeded == at_end[block] || (at_end[block] = seeded; changed = true)
        end
    end
    seeds, draws, returns = true, false, false
    for (block, info) in enumerate(blocks)
        seeded = at_start(block)
        for index in info.stmts
            index in flow.draws && !seeded && (draws = true)
            index in reseed && (seeded = true)
            statement = flow.ir.stmts[index][:stmt]
            statement isa Core.ReturnNode && isdefined(statement, :val) && (returns = true; seeds &= seeded)
        end
    end
    return seeds && returns, draws
end

"""
Library line of first draw of default RNG in instance with `flow` that names one (`engine.md`, Effect kinds): site of
callee summary at draw, else library line of draw statement in `sites` (`library_sites`). `nothing` when no draw names
line.
"""
function draw_site!(flow::Flow, callees::Callees, sites::AbstractVector{Union{Nothing, LineNumberNode}})::Union{Nothing, LineNumberNode}
    for index in flow.draws
        for variant in callees.variants[index]
            site = summary!(callees, variant).rng.site
            isnothing(site) || return site
        end
        isnothing(sites[index]) || return sites[index]
    end
    return nothing
end

"""
Summary of instance of `method` from `flow` at fixpoint, with callee summaries from `callees`: caller-visible accesses,
stores of exported objects, result, release balance (`balance!`) and default RNG facts (`seed_facts!`, `draw_site!` with
library lines `sites`). `seed!` with seed it takes (`reseeds`) reseeds, and draws nothing first.
"""
function summarize!(flow::Flow, method::Method, callees::Callees, sites::AbstractVector{Union{Nothing, LineNumberNode}})::Summary
    held, thrown, unguarded = balance!(flow, callees)
    seeds, draws = reseeds(method, flow.ir) ? (true, false) : seed_facts!(flow, callees)
    rng = DefaultRng(seeds, draws, draw_site!(flow, callees, sites))
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
        exported_holds(held, exported), exported_holds(thrown, exported), unguarded_nodes, rng,
    )
end
