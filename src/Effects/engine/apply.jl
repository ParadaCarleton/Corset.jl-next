"""
Call statement `index` that applies callee summary: targets and derived type sources of each callee parameter, targets
of every callee fresh node (`nothing`: callee makes none), callee places mapped so far with and without origins below
(`beneath`), and type sources of arguments so far. Stores of later edges miss cached places until next round.
"""
struct CallSite
    arguments::Vector{Targets}
    derived::Vector{Sources}
    index::Int
    fresh::Union{Nothing, Targets}
    places::Dict{Place.Type, Targets}
    below::Dict{Place.Type, Targets}
    sources::Dict{Int, Sources}
end

"""
Call site at statement `index` of callee with `summary`: its fresh nodes merge into allocation at `index`, blind unless
merge is exact. One fresh node merges exactly; several need check (`merges_exactly`).
"""
function CallSite(arguments::AbstractVector{Targets}, derived::AbstractVector{Sources}, index::Integer, summary::Summary)::CallSite
    merged = summary.fresh == 0 ? nothing : Targets(Origin.Allocation(index) => (summary.fresh == 1 || merges_exactly(summary)) ? NO_DOUBT : BLIND_DOUBT)
    return CallSite(arguments, derived, index, merged, Dict{Place.Type, Targets}(), Dict{Place.Type, Targets}(), Dict{Int, Sources}())
end

"""Whether `node` is fresh object of callee."""
fresh_node(node::Node.Type)::Bool = @match node begin
    Node.Fresh(_) => true
    _ => false
end

"""
Whether fresh nodes of `summary` merge into one allocation without false targets. Fresh nodes must form one object:
every fresh node but one backs another (`Array` and its `Memory`); merged object backs itself. Independent objects
(two vectors in one tuple) would share caller stores after call. No slot step holds stores of two fresh nodes, and
fresh node with unknown slot or backing outside fresh nodes is only fresh node with stores.
"""
function merges_exactly(summary::Summary)::Bool
    holders, stored, open, backs = Dict{Step.Type, Node.Type}(), Set{Node.Type}(), Set{Node.Type}(), Set{Node.Type}()
    for (node, step) in keys(summary.edges)
        fresh_node(node) || continue
        push!(stored, node)
        get!(holders, step, node) == node || return false
    end
    for node in keys(summary.spread)
        fresh_node(node) && push!(open, node)
    end
    for (node, nodes) in summary.backing
        fresh_node(node) || continue
        all(fresh_node, keys(nodes)) || push!(open, node)
        # Node that backs itself is earlier merge of one object (`[x]` calls `Vector(undef, 1)`).
        union!(backs, Iterators.filter(other -> fresh_node(other) && other != node, keys(nodes)))
    end
    summary.fresh - length(backs) == 1 || return false
    return isempty(open) || (length(open) == 1 && stored ⊆ open)
end

"""Targets of callee `place` at `site`, mapped once per call statement and round."""
site_place!(flow::Flow, site::CallSite, place::Place.Type)::Targets = get!(() -> map_place!(flow, place, site.arguments), site.places, place)

"""Targets of callee `place` at `site` with origins below them (`beneath`), found once per call statement and round."""
site_below!(flow::Flow, site::CallSite, place::Place.Type)::Targets = get!(() -> beneath(flow, site_place!(flow, site, place)), site.below, place)

"""
Targets of callee `node` at `site`; every fresh node of callee merges into allocation at call statement. Result is
shared by later calls at `site`: callers only read it.
"""
function map_node!(flow::Flow, node::Node.Type, site::CallSite)::Targets
    return @match node begin
        Node.Placed(place) => site_place!(flow, site, place)
        Node.Fresh(_) => something(site.fresh)
        Node.Outside() => site_place!(flow, site, Place.At(Root.Elsewhere(), NO_STEPS))
    end
end

"""
Targets of each callee parameter at call `index` of `method` with `operands`. Parameters past last fixed operand take
any `Rest` element. Vararg method packs trailing operands into allocation; `Rest` elements go to its unknown slot.
"""
function parameter_targets!(flow::Flow, index::Integer, method::Method, operands::AbstractVector{Operand.Type})::Vector{Targets}
    given = Targets[operand_targets!(flow, operand) for operand in operands if !is_rest(operand)]
    rest = union_targets(operand_targets!(flow, operand) for operand in operands if is_rest(operand))
    fixed = method.isva ? method.nargs - 1 : method.nargs
    arguments = [given[1:min(fixed, length(given))]; [rest for _ in (length(given) + 1):fixed]]
    method.isva || return arguments
    vararg = Targets(Origin.Allocation(index) => NO_DOUBT)
    for (position, targets) in enumerate(given[(fixed + 1):end])
        store!(flow, vararg, Step.Position(position), targets)
    end
    isempty(rest) || store!(flow, vararg, nothing, rest)
    return [arguments; vararg]
end

"""Derived type sources of each callee parameter, grouped from call `operands` as `parameter_targets!` groups targets."""
function parameter_derived(flow::Flow, method::Method, operands::AbstractVector{Operand.Type})::Vector{Sources}
    given = Sources[derived_of(flow, operand) for operand in operands if !is_rest(operand)]
    rest = reduce(|, (derived_of(flow, operand) for operand in operands if is_rest(operand)); init = Sources(0))
    fixed = method.isva ? method.nargs - 1 : method.nargs
    derived = [position <= length(given) ? given[position] : rest for position in 1:fixed]
    method.isva && push!(derived, reduce(|, @view(given[(fixed + 1):end]); init = rest))
    return derived
end

"""Union of targets of callee `nodes` at `site`, each raised to its node doubt (`caller_doubt!`)."""
function map_nodes!(flow::Flow, nodes::Nodes, site::CallSite)::Targets
    found = Targets()
    for (node, doubt) in nodes
        mapped = map_node!(flow, node, site)
        # Flow stays same over node, so its doubt maps once.
        isempty(mapped) || add_all!(found, mapped, caller_doubt!(flow, site, doubt))
    end
    return found
end

"""
Callee `doubt` at `site`: each parameter source becomes type sources of its argument (`type_sources`). Parameter
without argument is doubt in code.
"""
function caller_doubt!(flow::Flow, site::CallSite, doubt::Doubt)::Doubt
    sources_of(doubt) & PARAMETERS != 0 || return doubt
    sources, pending = sources_of(doubt) & ~PARAMETERS, sources_of(doubt) & PARAMETERS
    while pending != 0
        position = trailing_zeros(pending)
        pending &= pending - Sources(1)
        sources |= argument_sources!(flow, site, position)
    end
    return Doubt(Level.code, sources)
end

"""Type sources of argument `position` at `site`, found once per call statement and round; doubt in code past arguments."""
function argument_sources!(flow::Flow, site::CallSite, position::Integer)::Sources
    position <= length(site.arguments) || return INHERENT
    haskey(site.sources, position) || (site.sources[position] = type_sources(flow, site.arguments[position], site.derived[position]))
    return site.sources[position]
end

"""
Apply callee `summary` of `variant` at call statement `index` with `operands` (`engine.md`, Calls, steps 3 and 4):
stores and result now. Accesses go into `writes` and `reads`, or into callback record when `defers` and callable holds
caller object (`deferred`). Vararg tuple becomes allocation at `index`. Settled round (`Flow`) skips stores: they
change nothing there. `task`: callee is body of new task at `index` (`spawn!`), so result goes into task.
"""
function apply!(flow::Flow, writes::OriginAccesses, reads::OriginAccesses, index::Integer, summary::Summary, variant::Variant, operands::AbstractVector{Operand.Type}, defers::Bool, callees::Callees, task::Bool)::Nothing
    method = first(variant).def::Method
    arguments = parameter_targets!(flow, index, method, operands)
    site = CallSite(arguments, parameter_derived(flow, method, operands), index, summary)
    summary.closed_world && (flow.closed_world = true)
    summary.cut && (flow.cut = true)
    flow.settled || apply_stores!(flow, site, summary, task)
    if defers && deferred(arguments)
        defer!(flow, index, (variant, arguments))
    else
        apply_accesses!(flow, writes, reads, site, summary, defers, callees, nothing, scheduler_access(flow, method, operands))
    end
    return nothing
end

"""
Whether call of `method` with `operands` in `flow` is scheduler access to `Task` field: scheduler instance calls Base
property accessor on scheduler field (`scheduler_field`). Accessor runs field access of its caller, so caller kind holds.
"""
function scheduler_access(flow::Flow, method::Method, operands::AbstractVector{Operand.Type})::Bool
    Base.require_one_based_indexing(operands)
    (flow.scheduler && method.name in PROPERTY_ACCESSORS && Base.moduleroot(method.module) === Base && length(operands) >= 3) || return false
    field = operand_constant(flow.ir, operands[3])
    return !isnothing(field) && scheduler_field(operand_type(flow.ir, operands[2]), something(field))
end

"""
Accesses of callee `summary` at `site` into `writes` and `reads`, and its callback records: record waits again when
`defers` and callable still holds caller object, else resolves here. `seen` holds records resolved at site; first
record resolved makes it, since most calls have none. Only settled round (`Flow`) maps accesses: round empties them
first. Every round resolves records, so variants of records count as read (`summary!`). `scheduled`: task state access
of callee is scheduler access of caller (`scheduler_access`).
"""
function apply_accesses!(flow::Flow, writes::OriginAccesses, reads::OriginAccesses, site::CallSite, summary::Summary, defers::Bool, callees::Callees, seen::Union{Nothing, AbstractSet{Deferred}}, scheduled::Bool)::Nothing
    flow.settled && map_accesses!(flow, writes, reads, site, summary, scheduled)
    for callback in summary.callbacks
        record = (callback.variant, Targets[map_nodes!(flow, nodes, site) for nodes in callback.parameters])
        if defers && deferred(last(record))
            defer!(flow, site.index, record)
        else
            isnothing(seen) && (seen = Set{Deferred}())
            resolve!(flow, writes, reads, site.index, record, defers, callees, seen)
        end
    end
    return nothing
end

"""
Writes and reads of callee `summary` at `site` into `writes` and `reads`, each mapped onto caller objects. Callee place
that maps to one of several caller objects gives `possible` write on each (`alternative_access!`). `scheduled` call
gives audited state for task state (`scheduler_access`). Default RNG read of callee that draws before reseed is draw
of call (`draw!`).
"""
function map_accesses!(flow::Flow, writes::OriginAccesses, reads::OriginAccesses, site::CallSite, summary::Summary, scheduled::Bool)::Nothing
    caller_kind(kind::EffectKind.T)::EffectKind.T = scheduled && kind == EffectKind.task_local ? EffectKind.audited : kind
    for ((place, below, kind), effect) in summary.writes
        direct, objects = access_objects!(flow, site, place, below, caller_kind(kind))
        alternative_access!(writes, direct, objects, below, Effect(caller_doubt!(flow, site, effect.doubt), site.index, effect.reason), caller_kind(kind))
    end
    for ((place, below, kind), effect) in summary.reads
        access!(reads, last(access_objects!(flow, site, place, below, caller_kind(kind))), below, Effect(caller_doubt!(flow, site, effect.doubt), site.index, effect.reason), caller_kind(kind))
        summary.rng.draws && draw!(flow, site.index, caller_kind(kind))
    end
    return nothing
end

"""
Caller objects at callee `place` at `site`, and objects access of `kind` on it (or `below` it) reaches. Task state and
audited access (`UNMAPPED_KINDS`) on `Elsewhere` stay on unknown object: current task or Base object. Other access to
object reaches each outside object. Access to object reaches its memory backing too (`with_backing!`).
"""
function access_objects!(flow::Flow, site::CallSite, place::Place.Type, below::Bool, kind::EffectKind.T)::Tuple{Targets, Targets}
    kind in UNMAPPED_KINDS && root_of(place) == Root.Elsewhere() && return (unknown(NO_DOUBT), unknown(NO_DOUBT))
    direct = site_place!(flow, site, place)
    return (direct, below ? site_below!(flow, site, place) : with_backing!(flow, direct))
end

"""
`objects` and each memory backing chain from them reaches. Callee place holds memory of its object (`backing_field` adds
no step), so access to owner may land on memory alone or owner alone: `Base.wrap(Array, m, n)` gives `possible` access
to `m`, as `pop!` changes wrapper alone. Each link counts as work; walk stops past limit.
"""
function with_backing!(flow::Flow, objects::Targets)::Targets
    any(origin -> haskey(flow.backing, origin), keys(objects)) || return objects
    found, pending = copy(objects), collect(keys(objects))
    while !isempty(pending) && !over_budget(flow)
        origin = pop!(pending)
        backing = get(flow.backing, origin, nothing)
        isnothing(backing) && continue
        for (memory, flag) in backing
            over_budget(flow) && break
            flow.work += 1
            add!(found, memory, most(most(flag, CODE_DOUBT), found[origin])) && push!(pending, memory)
        end
    end
    return found
end

"""
Resolve callback `record` at call statement `index`: callable is fresh here, so accesses of its variant apply to record
targets. Record in `seen` adds nothing: recursion through callable repeats same accesses on same targets. Instance
that kept record took `closed_world` of variant already (`apply!`). Record keeps targets only, so no derived sources.
"""
function resolve!(flow::Flow, writes::OriginAccesses, reads::OriginAccesses, index::Integer, record::Deferred, defers::Bool, callees::Callees, seen::AbstractSet{Deferred})::Nothing
    record in seen && return nothing
    push!(seen, record)
    variant, arguments = record
    summary = summary!(callees, variant)
    site = CallSite(arguments, zeros(Sources, length(arguments)), index, summary)
    apply_accesses!(flow, writes, reads, site, summary, defers, callees, seen, false)
    return nothing
end

"""Keep callback `record` of call statement `index` for caller; its targets are copied, since values grow in round."""
function defer!(flow::Flow, index::Integer, record::Deferred)::Nothing
    push!(get!(Vector{Deferred}, flow.callbacks, index), (first(record), map(copy, last(record))))
    return nothing
end

"""
Whether call with callee parameter `arguments` (callable first) leaves accesses to caller: callable holds object below
caller parameter, and no argument holds fresh object. Caller merges fresh objects of instance into one (`map_node!`).
"""
function deferred(arguments::AbstractVector{Targets})::Bool
    any(parameter_origin, keys(first(arguments))) || return false
    return !any(targets -> any(fresh_origin, keys(targets)), arguments)
end

"""Whether `origin` is caller object at path below parameter: caller can tell which object it is."""
parameter_origin(origin::Origin.Type)::Bool = @match origin begin
    Origin.Caller(Place.At(Root.Parameter(_), _)) => true
    _ => false
end

"""
Callee stores between caller objects at `site`, global bindings and result. Result of `task` body goes into task
(`TASK_RESULT`), fresh object of call statement. New objects of body that caller cannot reach stay in task
(`caller_stored`).
"""
function apply_stores!(flow::Flow, site::CallSite, summary::Summary, task::Bool)::Nothing
    reached = task ? task_reached(summary) : nothing
    for ((node, step), nodes) in summary.edges
        stored = caller_stored(node, nodes, reached)
        isempty(stored) || store!(flow, map_node!(flow, node, site), step, map_nodes!(flow, stored, site))
    end
    for (node, nodes) in summary.backing
        stored = caller_stored(node, nodes, reached)
        isempty(stored) || store_backing!(flow, map_node!(flow, node, site), map_nodes!(flow, stored, site))
    end
    for (node, nodes) in summary.spread
        stored = caller_stored(node, nodes, reached)
        isempty(stored) || store!(flow, map_node!(flow, node, site), nothing, map_nodes!(flow, stored, site))
    end
    for (binding, nodes) in summary.bound
        bind!(flow, binding, map_nodes!(flow, nodes, site))
    end
    task && (store!(flow, Targets(Origin.Allocation(site.index) => NO_DOUBT), TASK_RESULT, map_nodes!(flow, summary.result, site)); return nothing)
    assign!(flow, site.index, address_targets!(flow, flow.ir.stmts[site.index][:type], map_nodes!(flow, summary.result, site)))
    return nothing
end

"""
Stored `nodes` from `holder` that caller sees; task body gives fresh nodes caller `reached` (`task_reached`). Body
keeps new object in unknown object, such as task storage of new task: caller load from it gives unknown object anyway.
"""
function caller_stored(holder::Node.Type, nodes::Nodes, reached::Union{Nothing, AbstractSet{Node.Type}})::Nodes
    isnothing(reached) && return nodes
    fresh_node(holder) && !(holder in reached) && return Nodes()
    holder == Node.Outside() || return nodes
    return filter(((node, _),) -> !fresh_node(node), nodes)
end

"""
Fresh nodes of task body `summary` that caller can reach: body result and stores into caller objects or globals,
then stores between fresh nodes. Store into unknown object reaches nothing (`caller_stored`).
"""
function task_reached(summary::Summary)::Set{Node.Type}
    inside, pending = Dict{Node.Type, Vector{Node.Type}}(), Node.Type[]
    stores = Iterators.flatten((((first(key), nodes) for (key, nodes) in summary.edges), summary.backing, summary.spread))
    for (holder, nodes) in stores
        fresh = [node for node in keys(nodes) if fresh_node(node)]
        if fresh_node(holder)
            append!(get!(Vector{Node.Type}, inside, holder), fresh)
        elseif holder != Node.Outside()
            append!(pending, fresh)
        end
    end
    for nodes in Iterators.flatten((values(summary.bound), (summary.result,)))
        append!(pending, (node for node in keys(nodes) if fresh_node(node)))
    end
    reached = Set{Node.Type}()
    while !isempty(pending)
        node = pop!(pending)
        node in reached && continue
        push!(reached, node)
        append!(pending, get(inside, node, Node.Type[]))
    end
    return reached
end

"""
Targets of value of `type` that `objects` give. Memory address (`Ptr`, `MemoryRef`) names memory: fresh owner in
`objects` gives memory backing it instead, as `load_field!` does. Other value keeps `objects`. Each backing link counts
as work; walk stops past limit.
"""
function address_targets!(flow::Flow, @nospecialize(type::Any), objects::Targets)::Targets
    type = CC.widenconst(type)
    (type isa DataType && type <: Union{Ptr, GenericMemoryRef}) || return objects
    found = Targets()
    for (origin, doubt) in objects
        backing = fresh_origin(origin) ? get(flow.backing, origin, nothing) : nothing
        isnothing(backing) && (add!(found, origin, doubt); continue)
        for (memory, flag) in backing
            over_budget(flow) && return found
            flow.work += 1
            add!(found, memory, most(flag, doubt))
        end
    end
    return found
end
