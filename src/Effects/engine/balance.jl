"""Hold counts by origin and resource during release balance; absent key holds exact 0."""
const Counts = Dict{Tuple{Origin.Type, Resource.T}, HoldCount}

"""Blind spot cause of hold Corset cannot count: resource operand with other targets, or `trylock`."""
const RELEASE_PATTERN = "release pattern"

"""Exact 0 hold: hold of absent key."""
const ZERO_HOLD = HoldCount(0, Level.none, 0, "")

"""Whether `hold` is exact 0."""
balanced(hold::HoldCount)::Bool = hold.level == Level.none && hold.count == 0

"""Whether `hold` may hold resource: count above 0, or count Corset does not know."""
holding(hold::HoldCount)::Bool = hold.level != Level.none || hold.count > 0

"""Earlier of statements `first` and `second`; 0 is no statement."""
earlier(first::Integer, second::Integer)::Int = first == 0 ? second : second == 0 ? first : min(first, second)

"""Blind spot cause of `first` and `second` at `level`: least cause of blind holds, so rounds agree; none below blind."""
function blind_reason(level::Level.T, first::HoldCount, second::HoldCount)::String
    level == Level.blind || return ""
    return minimum(hold.reason for hold in (first, second) if hold.level == Level.blind)
end

"""Hold after `change` follows `hold`: exact sum, else most doubt. Cause of hold stays unless hold is 0."""
function plus(hold::HoldCount, change::HoldCount)::HoldCount
    level = max(hold.level, change.level)
    return HoldCount(hold.count + change.count, level, balanced(hold) ? change.cause : hold.cause, blind_reason(level, hold, change))
end

"""Join of holds `first` and `second` of one key: equal exact counts stay, else unknown (`code`); blind stays."""
function join_hold(first::HoldCount, second::HoldCount)::HoldCount
    cause = earlier(first.cause, second.cause)
    first.level == second.level == Level.none && first.count == second.count && return HoldCount(first.count, Level.none, cause, "")
    level = max(first.level, second.level, Level.code)
    return HoldCount(0, level, cause, blind_reason(level, first, second))
end

"""Set hold of `key` in `state`; exact 0 leaves it absent."""
function set_hold!(state::Counts, key::Tuple{Origin.Type, Resource.T}, hold::HoldCount)::Nothing
    if balanced(hold)
        delete!(state, key)
    else
        state[key] = hold
    end
    return nothing
end

"""Apply hold `changes` to `state`."""
function apply_changes!(state::Counts, changes::Counts)::Nothing
    for (key, change) in changes
        set_hold!(state, key, plus(get(state, key, ZERO_HOLD), change))
    end
    return nothing
end

"""Join of hold states `first` and `second`, absent key 0."""
function join_counts(first::Counts, second::Counts)::Counts
    found = Counts()
    for key in union(keys(first), keys(second))
        set_hold!(found, key, join_hold(get(first, key, ZERO_HOLD), get(second, key, ZERO_HOLD)))
    end
    return found
end

"""Join of `state` into `found`; `nothing` found takes `state`."""
join_into(found::Union{Nothing, Counts}, state::Counts)::Counts = isnothing(found) ? copy(state) : join_counts(found, state)

"""
Origin that resource operand with `targets` names (`engine.md`, Release balance): one caller object at exact path, or
one fresh object, since merged fresh objects of callee count together. `nothing` for other targets.
"""
function resource_origin(targets::Targets)::Union{Nothing, Origin.Type}
    length(targets) == 1 || return nothing
    origin, doubt = only(targets)
    return @match origin begin
        Origin.Caller(Place.At(_, _)) => level_of(doubt) == Level.none ? origin : nothing
        Origin.Allocation(_) => origin
        _ => nothing
    end
end

"""Add `change` of `resource` on operand with `targets` to `changes`; operand without one origin gives blind hold on each."""
function add_change!(changes::Counts, targets::Targets, resource::Resource.T, change::HoldCount)::Nothing
    origin = resource_origin(targets)
    if isnothing(origin) || change.level == Level.blind
        blind = HoldCount(0, Level.blind, change.cause, change.level == Level.blind ? change.reason : RELEASE_PATTERN)
        foreach(target -> apply_changes!(changes, Counts((target, resource) => blind)), keys(targets))
    else
        apply_changes!(changes, Counts((origin, resource) => change))
    end
    return nothing
end

"""Changes callee `holds` make at `site`: each node maps to caller targets (`map_node!`); cause is call statement."""
function site_changes!(flow::Flow, site::CallSite, holds::HoldCounts)::Counts
    changes = Counts()
    for ((node, resource), hold) in holds
        add_change!(changes, map_node!(flow, node, site), resource, HoldCount(hold.count, hold.level, site.index, hold.reason))
    end
    return changes
end

"""
Add hold changes at normal return of callee `summary` at `site` to `normal`, and of callback records it resolves here:
record waits again when `defers` and callable still holds caller object (`apply_accesses!`). Gives change at throw:
callee throw-exit count joined with throw of each record.
"""
function summary_changes!(flow::Flow, normal::Counts, site::CallSite, summary::Summary, defers::Bool, callees::Callees, seen::AbstractSet{Deferred})::Counts
    apply_changes!(normal, site_changes!(flow, site, summary.held))
    thrown = site_changes!(flow, site, summary.thrown)
    for callback in summary.callbacks
        record = (callback.variant, Targets[map_nodes!(flow, nodes, site) for nodes in callback.parameters])
        defers && deferred(last(record)) || record in seen || begin
            push!(seen, record)
            variant, arguments = record
            inner = summary!(callees, variant)
            inner_site = CallSite(arguments, zeros(Sources, length(arguments)), site.index, inner.fresh)
            thrown = join_counts(thrown, summary_changes!(flow, normal, inner_site, inner, defers, callees, seen))
        end
    end
    return thrown
end

"""
Hold changes of dispatched call `index` with `operands` to one `variant` at normal return and at throw. Call that
leaves callback record for caller (`deferred`) leaves its changes there too.
"""
function variant_changes!(flow::Flow, index::Integer, operands::AbstractVector{Operand.Type}, variant::Variant, defers::Bool, callees::Callees)::Tuple{Counts, Counts}
    summary, method = summary!(callees, variant), first(variant).def::Method
    arguments = parameter_targets!(flow, index, method, operands)
    defers && deferred(arguments) && return (Counts(), Counts())
    site = CallSite(arguments, parameter_derived(flow, method, operands), index, summary.fresh)
    normal = Counts()
    return normal, summary_changes!(flow, normal, site, summary, defers, callees, Set{Deferred}())
end

"""
Hold changes of call statement `index` at normal return and at throw (`engine.md`, Release balance): primitive table
entry, else callee counts; join of methods joins them. Throw of primitive skips its acquire and keeps its release.
Other calls change no count.
"""
function call_changes!(flow::Flow, callees::Callees, index::Integer)::Tuple{Counts, Counts}
    outcome = flow.outcomes[index]
    isnothing(outcome) && return (Counts(), Counts())
    operands = @match something(outcome) begin
        Outcome.Dispatch(_, operands) => operands
        _ => return (Counts(), Counts())
    end
    found = flow.primitives[index]
    if !isnothing(found)
        targets = found.operand == 0 ? Targets(Origin.Allocation(index) => NO_DOUBT) : operand_targets!(flow, operands[found.operand])
        change = isnothing(found.change) ? HoldCount(0, Level.blind, index, RELEASE_PATTERN) : HoldCount(found.change, Level.none, index, "")
        normal = Counts()
        balanced(change) || add_change!(normal, targets, found.resource, change)
        return normal, Counts(key => hold for (key, hold) in normal if hold.level == Level.none && hold.count < 0)
    end
    variants = callees.variants[index]
    defers = !flow.flush && !flow.message[index] && length(variants) == 1
    members = [variant_changes!(flow, index, operands, variant, defers, callees) for variant in variants]
    length(members) == 1 && return only(members)
    return mapreduce(first, join_counts, members), mapreduce(last, join_counts, members)
end

"""Heads of IR expressions that can throw: calls and allocations. Flag `nothrow` decides whether each one does."""
const THROWING_HEADS = (:call, :foreigncall, :new, :splatnew, :throw_undef_if_not)

"""Whether statement `index` of `ir` may throw: call or global read without compiler `nothrow` flag."""
function may_throw(ir::CC.IRCode, index::Integer)::Bool
    statement = ir.stmts[index][:stmt]
    statement isa GlobalRef || (statement isa Expr && statement.head in THROWING_HEADS) || return false
    return ir.stmts[index][:flag] & CC.IR_FLAG_NOTHROW == 0
end

"""
Catch block of statement `index` of `ir` with `handlers` (`CC.compute_trycatch`): block of innermost `try` that
catches; 0 outside every `try`. Scope `enter` (`catch_dest` 0) catches nothing, so its outer `try` decides.
"""
function catch_block(ir::CC.IRCode, handlers::Union{Nothing, CC.HandlerInfo}, index::Integer)::Int
    isnothing(handlers) && return 0
    handler = handlers.handler_at[index][1]
    while handler != 0
        enter = CC.get_enter_idx(handlers.handlers[handler])
        destination = (ir.stmts[enter][:stmt]::Core.EnterNode).catch_dest
        destination == 0 || return destination
        handler = handlers.handler_at[enter][1]
    end
    return 0
end

"""
Path state of release balance (property simulation, as in ESP): hold counts, and values of branch conditions path took.
`l && lock(x); …; l && unlock(x)` balances: path that holds knows `l`.
"""
const Path = Tuple{Counts, Dict{Any, Bool}}

"""Paths per block entry before they join into one: count that grows round loop collapses there."""
const PATH_LIMIT = 4

"""Conditions both `first` and `second` paths agree on."""
agreed(first::AbstractDict{Any, Bool}, second::AbstractDict{Any, Bool})::Dict{Any, Bool} = Dict{Any, Bool}(key => value for (key, value) in first if get(second, key, !value) == value)

"""
Join `path` into `paths`: path with equal counts keeps conditions both agree on; past `PATH_LIMIT` paths, all join into
one. Return whether `paths` changed.
"""
function add_path!(paths::AbstractVector{Path}, path::Path)::Bool
    counts, conditions = path
    at = findfirst(existing -> first(existing) == counts, paths)
    if isnothing(at)
        push!(paths, (copy(counts), copy(conditions)))
    else
        kept = agreed(last(paths[at]), conditions)
        kept == last(paths[at]) && return false
        paths[at] = (counts, kept)
    end
    if length(paths) > PATH_LIMIT
        joined = (mapreduce(first, join_counts, paths), mapreduce(last, agreed, paths))
        empty!(paths)
        push!(paths, joined)
    end
    return true
end

"""Join `path` into entry of `block`; queue block in `pending` when its entry changes."""
function flow_into!(entries::AbstractVector{<:AbstractVector{Path}}, pending::BitSet, block::Integer, path::Path)::Nothing
    Base.require_one_based_indexing(entries)
    add_path!(entries[block], path) && push!(pending, block)
    return nothing
end

"""Value of branch `condition` on path with `conditions`: constant, condition path took, else `nothing`."""
function condition_value(conditions::AbstractDict{Any, Bool}, @nospecialize(condition::Any))::Union{Nothing, Bool}
    condition isa Bool && return condition
    return get(conditions, condition, nothing)
end

"""
Successors of `block` that path with `conditions` reaches, each with conditions it adds. Branch on known condition takes
one side; catch block of `enter` takes states of statements that throw only.
"""
function path_successors(ir::CC.IRCode, block::Integer, conditions::AbstractDict{Any, Bool})::Vector{Pair{Int, Dict{Any, Bool}}}
    terminator = ir.stmts[last(ir.cfg.blocks[block].stmts)][:stmt]
    successors = ir.cfg.blocks[block].succs
    if terminator isa Core.GotoIfNot && terminator.dest != block + 1
        value = condition_value(conditions, terminator.cond)
        taken(side::Bool)::Dict{Any, Bool} = terminator.cond isa Bool ? conditions : merge(conditions, Dict{Any, Bool}(terminator.cond => side))
        isnothing(value) && return [block + 1 => taken(true), terminator.dest => taken(false)]
        return [(something(value) ? block + 1 : terminator.dest) => conditions]
    end
    skipped = terminator isa Core.EnterNode ? terminator.catch_dest : 0
    return [successor => conditions for successor in successors if successor != skipped]
end

"""Record in `unguarded` hold of `key` that throw at `index` skips: definite before `possible` before blind, then first throw."""
function unguard!(unguarded::AbstractDict{Tuple{Origin.Type, Resource.T}, Unguarded}, key::Tuple{Origin.Type, Resource.T}, hold::HoldCount, index::Integer)::Nothing
    old = get(unguarded, key, nothing)
    isnothing(old) || (hold.level, index) < (old.hold.level, old.throws) || return nothing
    unguarded[key] = (hold = hold, throws = index)
    return nothing
end

"""
Release balance of `flow` at fixpoint (`engine.md`, Release balance): forward dataflow of hold counts over CFG blocks,
one state per path (`Path`). Statement that may throw has edge to its catch block, else to throw exit. Gives counts at
normal exit and throw exit, and holds own throws skip: hold before throw that throw still holds.
"""
function balance!(flow::Flow, callees::Callees)::Tuple{Counts, Counts, Dict{Tuple{Origin.Type, Resource.T}, Unguarded}}
    ir = flow.ir
    blocks, handlers = ir.cfg.blocks, CC.compute_trycatch(ir)
    entries = [Path[] for _ in blocks]
    push!(entries[1], (Counts(), Dict{Any, Bool}()))
    pending, changes = BitSet(1), Dict{Int, Tuple{Counts, Counts}}()
    normal, thrown, unguarded = nothing, nothing, Dict{Tuple{Origin.Type, Resource.T}, Unguarded}()
    while !isempty(pending)
        block = popfirst!(pending)
        for (counts, conditions) in copy(entries[block])
            state, known = copy(counts), copy(conditions)
            for index in blocks[block].stmts
                statement = ir.stmts[index][:stmt]
                # Statement in loop defines its value again: condition path took on old value no longer holds.
                delete!(known, Core.SSAValue(index))
                statement isa Core.ReturnNode && isdefined(statement, :val) && (normal = join_into(normal, state))
                done, throws = get!(() -> call_changes!(flow, callees, index), changes, index)
                if may_throw(ir, index)
                    exceptional = copy(state)
                    apply_changes!(exceptional, throws)
                    destination = catch_block(ir, handlers, index)
                    if destination == 0
                        thrown = join_into(thrown, exceptional)
                        for (key, hold) in exceptional
                            holding(hold) && holding(get(state, key, ZERO_HOLD)) && unguard!(unguarded, key, hold, index)
                        end
                    else
                        flow_into!(entries, pending, destination, (exceptional, known))
                    end
                end
                apply_changes!(state, done)
            end
            foreach(((successor, taken),) -> flow_into!(entries, pending, successor, (state, taken)), path_successors(ir, block, known))
        end
    end
    return something(normal, Counts()), something(thrown, Counts()), unguarded
end

"""Hold counts of `counts` on nodes caller can see: fresh origin counts only when it escapes (`escaping`)."""
function exported_holds(counts::Counts, exported::AbstractSet{Origin.Type})::HoldCounts
    return HoldCounts((node_of(origin), resource) => hold for ((origin, resource), hold) in counts if !fresh_origin(origin) || origin in exported)
end
