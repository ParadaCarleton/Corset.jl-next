# Release balance of name tier (`effects.md`, Release balance): hold counts per resource over paths of one unit.

"""
Resource of hold: caller place that holds it, or IR statement of value that names it (`open` result, local lock); and
its kind: lock or `Semaphore` slot (`synchronization`), or file (`io`).
"""
const Resource = Tuple{Union{Place.Type, Int}, EffectKind.T}

"""Hold count of resource on one path: `count`, `nothing` when unknown; IR statement of acquire that started hold."""
struct Hold
    count::Union{Nothing, Int}
    acquire::Int
end

"""Hold counts by resource on one path; absent resource holds exact 0."""
const Counts = Dict{Resource, Hold}

"""Change of call to hold of resource: step of count, or `nothing` when count becomes unknown."""
const Change = Pair{Resource, Union{Nothing, Int}}

"""Acquire and release functions of one operand, by function: kind of resource, then step of count."""
const PRIMITIVES = IdDict{Any, Tuple{EffectKind.T, Int}}(
    lock => (EffectKind.synchronization, 1), unlock => (EffectKind.synchronization, -1),
    Base.acquire => (EffectKind.synchronization, 1), Base.release => (EffectKind.synchronization, -1), close => (EffectKind.io, -1),
)

"""Paths per block entry before they join into one: count that grows round loop collapses there."""
const PATH_LIMIT = 4

"""
Path state of release balance (property simulation, as in ESP): hold counts, values of branch conditions path took,
conditions that join dropped, and `blurred`. `l && lock(x); …; l && unlock(x)` balances: path that holds knows `l`.
Branch on dropped condition can pair counts of one joined path with side of other, so path becomes `blurred`: its
facts are `possible`.
"""
struct Path
    counts::Counts
    conditions::Dict{Any, Bool}
    dropped::Set{Any}
    blurred::Bool
end

"""Copy of `path` that edits leave `path` unchanged."""
copy_path(path::Path)::Path = Path(copy(path.counts), copy(path.conditions), copy(path.dropped), path.blurred)

"""
Identity of resource that IR `operand` of `walk` names: its one caller place, else IR statement of its value
(`resource_root`); `nothing` for literal object. Place that summarizes several objects (`summarized`) names none of
them: each load is its own resource.
"""
function resource_identity(walk::Walk, @nospecialize(operand::Any))::Union{Nothing, Place.Type, Int}
    value = operand_value(walk, operand)
    !value.fresh && length(value.places) == 1 && !summarized(only(value.places)) && return only(value.places)
    root = resource_root(walk, operand)
    return root isa Core.SSAValue ? root.id : nothing
end

"""
IR value of `operand` under `π` nodes (`underlying`) and catch entry: `PhiC` node whose `ϒ` nodes all pass one value
gives that value. Value live into catch block passes `PhiC`, so release in `finally` names value of `try` body.
"""
function resource_root(walk::Walk, @nospecialize(operand::Any))::Any
    root = underlying(walk, operand)
    root isa Core.SSAValue || return root
    statement = walk.ir.stmts[root.id][:stmt]
    statement isa Core.PhiCNode || return root
    sources = Set{Any}()
    for upsilon in statement.values
        upsilon isa Core.SSAValue || return root
        node = walk.ir.stmts[upsilon.id][:stmt]
        node isa Core.UpsilonNode || return root
        isdefined(node, :val) || return root
        push!(sources, underlying(walk, node.val))
    end
    return length(sources) == 1 ? only(sources) : root
end

"""
Hold change of statement `index` of `walk`: acquire or release of one operand (`PRIMITIVES`), or `open` that gives file.
Function form (`lock(f, l)`, `open(f, path)`) releases inside callee. `trylock` forks path (`unguarded_holds`).
"""
function hold_change(walk::Walk, index::Integer)::Union{Nothing, Change}
    statement = walk.ir.stmts[index][:stmt]
    statement isa Expr || return nothing
    statement.head === :call || return nothing
    callee, operands = call_parts(walk, statement)
    (isnothing(operands) || isempty(operands) || callable(walk, operands[1])) && return nothing
    callee === open && return operand_type(walk, Core.SSAValue(index)) <: IOStream ? (index, EffectKind.io) => 1 : nothing
    entry = get(PRIMITIVES, callee, nothing)
    (isnothing(entry) || length(operands) != 1) && return nothing
    kind, step = entry
    kind === EffectKind.io && !(operand_type(walk, operands[1]) <: IOStream) && return nothing
    identity = resource_identity(walk, operands[1])
    # Acquire of literal object starts hold of unknown count; its release ends hold of no tracked resource.
    return isnothing(identity) ? (index, kind) => (step > 0 ? nothing : step) : (identity, kind) => step
end

"""Resource that `trylock` statement `index` of `walk` tries; `nothing` for other statement or literal lock."""
function try_resource(walk::Walk, index::Integer)::Union{Nothing, Resource}
    operand = only_operand(walk, index, trylock)
    isnothing(operand) && return nothing
    identity = resource_identity(walk, something(operand))
    return isnothing(identity) ? nothing : (identity, EffectKind.synchronization)
end

"""Operand of call statement `index` of `walk` to `callee` with one operand; `nothing` for other statement."""
function only_operand(walk::Walk, index::Integer, @nospecialize(callee::Any))::Union{Nothing, Some{Any}}
    statement = walk.ir.stmts[index][:stmt]
    statement isa Expr || return nothing
    statement.head === :call || return nothing
    called, operands = call_parts(walk, statement)
    return called === callee && !isnothing(operands) && length(operands) == 1 ? Some{Any}(operands[1]) : nothing
end

"""Whether `place` can name several objects: summary of elements (`Element` step) or whole subtree (`Deep`)."""
summarized(place::Place.Type)::Bool = @match place begin
    Place.Deep(_) => true
    Place.At(_, steps) => any(
        step -> (
            @match step begin
                Step.Element() => true
                _ => false
            end
        ), steps
    )
end

"""
Roots that can hold fresh resource value, and statements where caller-visible root (argument, global, value with place)
takes it: code elsewhere can reach value after them, so package call they can run before can release it.
"""
struct ValueReach
    holders::Set{Any}
    escapes::BitSet
end

"""Reach of fresh resource values of one walk, kept per value; `users` of each root, built on first use, serve all."""
mutable struct Reaches
    users::Union{Nothing, Dict{Any, Vector{Int}}}
    values::Dict{Int, ValueReach}
end

"""Reaches of walk before any value asks."""
Reaches()::Reaches = Reaches(nothing, Dict{Int, ValueReach}())

"""Reach of resource value `identity` of `walk` that `reaches` keeps; computes and keeps it first time."""
function value_reach!(reaches::Reaches, walk::Walk, identity::Integer)::ValueReach
    haskey(reaches.values, identity) && return reaches.values[identity]
    isnothing(reaches.users) && (reaches.users = root_users(walk))
    return reaches.values[identity] = value_reach(walk, identity, something(reaches.users))
end

"""Statements of `walk` that use each root (`resource_root`) as operand."""
function root_users(walk::Walk)::Dict{Any, Vector{Int}}
    users = Dict{Any, Vector{Int}}()
    for index in 1:length(walk.ir.stmts), reference in CC.userefs(walk.ir.stmts[index][:stmt])
        push!(get!(Vector{Int}, users, resource_root(walk, reference[])), index)
    end
    return users
end

"""
Reach of resource value `identity` of `walk` with statement `users` of each root: value itself, result of tuple, `new`,
holding call (`held_operands`) or `φ` node that takes holder, and result and mutable operands of call that takes holder:
call can store holder there. Stream and lock calls (`IO_FUNCTIONS`, `SYNC_FUNCTIONS`) store their operands nowhere.
"""
function value_reach(walk::Walk, identity::Integer, users::AbstractDict{Any, <:AbstractVector{<:Integer}})::ValueReach
    holders, pending, escapes = Set{Any}(Any[Core.SSAValue(identity)]), Any[Core.SSAValue(identity)], BitSet()
    while !isempty(pending)
        for index in get(users, pop!(pending), Int[]), root in holder_roots(walk, index, holders)
            # Each store escapes on own path, even into root earlier store already reached.
            (root isa Core.SSAValue && isempty(walk.values[root.id].places)) || push!(escapes, index)
            root in holders && continue
            push!(holders, root)
            push!(pending, root)
        end
    end
    return ValueReach(holders, escapes)
end

"""Whether statement `from` of `cfg` can run before statement `to`: earlier in same block, or path from its block."""
function may_run_before(cfg::CC.CFG, from::Integer, to::Integer)::Bool
    source, target = CC.block_for_inst(cfg, from), CC.block_for_inst(cfg, to)
    source == target && from < to && return true
    seen, pending = BitSet(), copy(cfg.blocks[source].succs)
    while !isempty(pending)
        block = pop!(pending)
        block == target && return true
        block in seen && continue
        push!(seen, block)
        append!(pending, cfg.blocks[block].succs)
    end
    return false
end

# corset: allow bang-convention -- memo of reach answers; result never changes
"""
Whether IR `operand` of `walk` can reach `resource`: root that can hold resource value (`value_reach`, kept per value in
`reach`), or caller place at or above resource place, or above place of resource value (`locks` reaches `locks[1]`).
"""
function reaches(walk::Walk, @nospecialize(operand::Any), resource::Resource, reach::Reaches)::Bool
    identity = first(resource)
    identity isa Int && resource_root(walk, operand) in value_reach!(reach, walk, identity).holders && return true
    targets = identity isa Int ? walk.values[identity].places : Set{Place.Type}([identity])
    value = operand_value(walk, operand)
    return any(place -> any(target -> covers(place, target), targets), Iterators.flatten((value.places, value.inner)))
end

"""Roots that statement `index` of `walk` makes hold value that one of `holders` holds (`value_reach`)."""
function holder_roots(walk::Walk, index::Integer, holders::AbstractSet)::Vector{Any}
    statement = walk.ir.stmts[index][:stmt]
    holds(@nospecialize(operand::Any))::Bool = resource_root(walk, operand) in holders
    if statement isa Core.PhiNode
        return any(position -> isassigned(statement.values, position) && holds(statement.values[position]), eachindex(statement.values)) ? Any[Core.SSAValue(index)] : Any[]
    end
    statement isa Expr || return Any[]
    any(holds, held_operands(walk, statement)) && return Any[Core.SSAValue(index)]
    statement.head === :call || return Any[]
    callee, operands = call_parts(walk, statement)
    (isnothing(operands) || !any(holds, operands)) && return Any[]
    (callee in IO_FUNCTIONS || callee in SYNC_FUNCTIONS) && return Any[]
    roots = Any[resource_root(walk, operand) for operand in operands if may_hold(operand_type(walk, operand))]
    may_hold(operand_type(walk, Core.SSAValue(index))) && push!(roots, Core.SSAValue(index))
    # Literal mutable object (constant global inferred into code) is caller-visible too.
    return Any[root for root in roots if root isa Union{Core.SSAValue, Core.Argument, GlobalRef} || ismutable(root isa QuoteNode ? root.value : root)]
end

"""Whether value of `type` can hold other object: neither plain (`PLAIN`) nor concrete bits type."""
may_hold(@nospecialize(type::Any))::Bool = !(type <: PLAIN) && !(isconcretetype(type) && isbitstype(type))

"""Whether object at `place` holds object at `other`: same place, `Deep` of its root, or exact path that `other` extends."""
function covers(place::Place.Type, other::Place.Type)::Bool
    place == other && return true
    return @match (place, other) begin
        (Place.Deep(root), Place.At(other_root, _)) => root == other_root
        (Place.Deep(root), Place.Deep(other_root)) => root == other_root
        (Place.At(root, steps), Place.At(other_root, other_steps)) => root == other_root && length(steps) <= length(other_steps) && steps == other_steps[1:length(steps)]
        _ => false
    end
end

"""Whether call of `callee` on `operands` in `walk` runs builtin, or one `Base` or `Core` method: neither releases resource."""
function trusted_call(walk::Walk, @nospecialize(callee::Any), operands::AbstractVector{Any})::Bool
    callee isa Core.Builtin && return true
    matches = Base._methods_by_ftype(Tuple{Core.Typeof(callee), Any[operand_type(walk, operand) for operand in operands]...}, 1, walk.world)
    return matches isa Vector && length(matches) == 1 && Base.moduleroot(only(matches).method.module) in (Base, Core)
end

"""
Resources of `counts` that call or allocation statement `index` of `walk` hands on: callee can release them. Trusted
call (`trusted_call`) hands on only what its function operands reach; `trusted` keeps answer per statement, `reach`
holders per resource value. Call that can run package code hands on resource value that escaped before it (`ValueReach`).
"""
function handed(walk::Walk, index::Integer, counts::Counts, trusted::AbstractDict{<:Integer, Bool}, reach::Reaches)::Vector{Resource}
    isempty(counts) && return Resource[]
    statement = walk.ir.stmts[index][:stmt]
    statement isa Expr || return Resource[]
    statement.head in (:call, :new) || return Resource[]
    operands, runs = statement.head === :new ? statement.args[2:end] : statement.args, statement.head === :call
    if statement.head === :call
        callee, arguments = call_parts(walk, statement)
        if !isnothing(callee) && !isnothing(arguments) && get!(() -> trusted_call(walk, callee, arguments), trusted, index)
            operands = Any[operand for operand in arguments if callable(walk, operand)]
            runs = !isempty(operands)
        end
    end
    escaped(resource::Resource)::Bool = first(resource) isa Int && any(escape -> may_run_before(walk.ir.cfg, escape, index), value_reach!(reach, walk, first(resource)).escapes)
    # Loop, not comprehension: comprehension would capture `operands` and `runs`, which code above assigns twice.
    found = Resource[]
    for resource in keys(counts)
        ((runs && escaped(resource)) || any(operand -> reaches(walk, operand, resource, reach), operands)) && push!(found, resource)
    end
    return found
end

"""Make count of `resource` in `counts` unknown, if path holds it."""
function forget!(counts::Counts, resource::Resource)::Nothing
    hold = get(counts, resource, nothing)
    isnothing(hold) || (counts[resource] = Hold(nothing, hold.acquire))
    return nothing
end

"""
Apply `change` of statement `index` to `counts`: exact sum, unknown step gives unknown count. Release of resource
path does not hold may release any hold of its kind, so those counts become unknown.
"""
function apply_change!(counts::Counts, change::Pair{<:Resource, <:Union{Nothing, Integer}}, index::Integer)::Nothing
    resource, step = change
    old = get(counts, resource, nothing)
    if isnothing(old) && something(step, 0) < 0
        foreach(key -> last(key) == last(resource) && forget!(counts, key), collect(keys(counts)))
        return nothing
    end
    old = something(old, Hold(0, index))
    count = isnothing(old.count) || isnothing(step) ? nothing : old.count + something(step)
    if count == 0
        delete!(counts, resource)
    else
        counts[resource] = Hold(count, old.count == 0 ? index : old.acquire)
    end
    return nothing
end

"""Join of hold counts `first` and `second`: equal exact counts stay, else unknown; earlier acquire stays."""
function join_counts(first::Counts, second::Counts)::Counts
    found = Counts()
    for resource in union(keys(first), keys(second))
        left, right = get(first, resource, nothing), get(second, resource, nothing)
        acquire = minimum(hold.acquire for hold in (left, right) if !isnothing(hold))
        found[resource] = Hold(!isnothing(left) && !isnothing(right) && left.count == right.count ? left.count : nothing, acquire)
    end
    return found
end

"""Conditions both `first` and `second` paths agree on."""
agreed(first::AbstractDict{Any, Bool}, second::AbstractDict{Any, Bool})::Dict{Any, Bool} = Dict{Any, Bool}(key => value for (key, value) in first if get(second, key, !value) == value)

"""
Join `path` into `paths`: path with equal counts and blur keeps conditions both agree on, and drops others (`Path`);
past `PATH_LIMIT` paths, all join into one (`joined_path`). Return whether `paths` changed.
"""
function add_path!(paths::AbstractVector{Path}, path::Path)::Bool
    at = findfirst(existing -> existing.counts == path.counts && existing.blurred == path.blurred, paths)
    if isnothing(at)
        push!(paths, copy_path(path))
    else
        existing = paths[at]
        kept = agreed(existing.conditions, path.conditions)
        dropped = union(existing.dropped, path.dropped, setdiff(union(keys(existing.conditions), keys(path.conditions)), keys(kept)))
        kept == existing.conditions && dropped == existing.dropped && return false
        paths[at] = Path(existing.counts, kept, dropped, existing.blurred)
    end
    if length(paths) > PATH_LIMIT
        joined = joined_path(paths)
        empty!(paths)
        push!(paths, joined)
    end
    return true
end

"""One path for all `paths`: joined counts, conditions all agree on; conditions some path knew or dropped stay dropped."""
function joined_path(paths::AbstractVector{Path})::Path
    conditions, dropped = reduce(agreed, [path.conditions for path in paths]), Set{Any}()
    # Typed loop: `union` of splatted key sets iterates abstract sets, which package methods invalidate.
    for path in paths, known in (keys(path.conditions), path.dropped), condition in known
        haskey(conditions, condition) || push!(dropped, condition)
    end
    return Path(reduce(join_counts, [path.counts for path in paths]), conditions, dropped, any(path -> path.blurred, paths))
end

"""
Successors of `block` of `ir` that `path` reaches, each with path state there. Branch on known condition takes one
side; branch on condition that can depend on condition join dropped (`may_depend!`) blurs path (`Path`). Catch block of `enter` takes states of statements that throw only.
"""
function path_successors(ir::CC.IRCode, block::Integer, path::Path)::Vector{Pair{Int, Path}}
    terminator = ir.stmts[last(ir.cfg.blocks[block].stmts)][:stmt]
    successors = ir.cfg.blocks[block].succs
    if terminator isa Core.GotoIfNot && terminator.dest != block + 1
        condition = terminator.cond
        value = condition isa Bool ? condition : get(path.conditions, condition, nothing)
        isnothing(value) || return [(something(value) ? block + 1 : terminator.dest) => copy_path(path)]
        blurred = path.blurred || may_depend!(Set{Int}(), ir, condition, path.dropped, DEPEND_DEPTH)
        taken(side::Bool)::Path = Path(copy(path.counts), merge(path.conditions, Dict{Any, Bool}(condition => side)), setdiff(path.dropped, (condition,)), blurred)
        return [block + 1 => taken(true), terminator.dest => taken(false)]
    end
    skipped = terminator isa Core.EnterNode ? terminator.catch_dest : 0
    return [successor => copy_path(path) for successor in successors if successor != skipped]
end

"""Statements `may_depend!` follows back from branch condition before it assumes dependence."""
const DEPEND_DEPTH = 16

"""
Whether branch `condition` of `ir` can depend on conditions in `dropped`, within `depth` statements: dropped value,
`φ` node (it picks value by path), call without compiler `:consistent` proof (it can read state branches wrote),
non-constant global, or operand that can depend. Adds each SSA value it walks to `visited`; walked value adds nothing,
so shared operands cost one visit.
"""
function may_depend!(visited::AbstractSet{<:Integer}, ir::CC.IRCode, @nospecialize(condition::Any), dropped::AbstractSet, depth::Integer)::Bool
    isempty(dropped) && return false
    condition in dropped && return true
    condition isa GlobalRef && return !isconst(condition)
    condition isa Core.SSAValue || return false
    # Walk that found dependence ended search, so walked value found none.
    condition.id in visited && return false
    push!(visited, condition.id)
    depth > 0 || return true
    statement = ir.stmts[condition.id][:stmt]
    statement isa Union{Core.PhiNode, Core.PhiCNode, Core.UpsilonNode} && return true
    calls = statement isa Expr && statement.head in (:call, :invoke, :foreigncall)
    calls && ir.stmts[condition.id][:flag] & CC.IR_FLAG_CONSISTENT == 0 && return true
    return any(reference -> may_depend!(visited, ir, reference[], dropped, depth - 1), CC.userefs(statement))
end

"""Heads of IR expressions that can throw: calls and allocations. Flag `nothrow` decides whether each one does."""
const THROWING_HEADS = (:call, :invoke, :foreigncall, :new, :splatnew, :throw_undef_if_not)

"""Whether statement `index` of `ir` may throw: call or global read without compiler `nothrow` flag."""
function may_throw(ir::CC.IRCode, index::Integer)::Bool
    statement = ir.stmts[index][:stmt]
    statement isa GlobalRef || (statement isa Expr && statement.head in THROWING_HEADS) || return false
    return ir.stmts[index][:flag] & CC.IR_FLAG_NOTHROW == 0
end

"""
Catch block of statement `index` of `ir` with `handlers` (`CC.compute_trycatch`): block of innermost `try` or scope
that catches; 0 outside every one.
"""
function catch_block(ir::CC.IRCode, handlers::Union{Nothing, CC.HandlerInfo}, index::Integer)::Int
    isnothing(handlers) && return 0
    handler = handlers.handler_at[index][1]
    handler == 0 && return 0
    enter = CC.get_enter_idx(handlers.handlers[handler])
    destination = (ir.stmts[enter][:stmt]::Core.EnterNode).catch_dest
    # Lowering gives each `enter` catch block, scope `enter` too; optimizer, which walk stops before, drops it.
    destination > 0 || error("`enter` without catch block at statement $enter of unoptimized code")
    return destination
end

"""
Holds that throw skips in unit `walk` with `spans` of its IR statements (F98): forward dataflow of hold counts over
CFG blocks, one state per path (`Path`). `trylock` forks path: success holds one more, and each side knows result.
Statement that may throw outside every `try` while path holds resource gives fact, unless statement changes that hold.
Exact count gives `definite`; unknown count, blurred path, or release of untracked resource of same kind, `possible`. First throw
per resource, `definite` first, stays.
"""
function unguarded_holds(walk::Walk, spans::AbstractVector{Span})::Vector{UnguardedHold}
    ir = walk.ir
    blocks, handlers = ir.cfg.blocks, CC.compute_trycatch(ir)
    entries, trusted, reach = [Path[] for _ in blocks], Dict{Int, Bool}(), Reaches()
    push!(entries[1], Path(Counts(), Dict{Any, Bool}(), Set{Any}(), false))
    pending, found = BitSet(1), Dict{Resource, Tuple{Confidence.T, Int, Int}}()
    while !isempty(pending)
        block = popfirst!(pending)
        for entry in copy(entries[block])
            forks, forked = [(copy_path(entry), first(blocks[block].stmts))], 0
            while !isempty(forks)
                path, start = pop!(forks)
                state, known = path.counts, path.conditions
                for index in start:last(blocks[block].stmts)
                    # Statement in loop defines its value again: condition path took on old value no longer holds.
                    delete!(known, Core.SSAValue(index))
                    delete!(path.dropped, Core.SSAValue(index))
                    change = hold_change(walk, index)
                    target = isnothing(change) ? nothing : first(change)
                    untracked = !isnothing(change) && something(last(change), 0) < 0 && !haskey(state, target)
                    foreach(resource -> resource == target || forget!(state, resource), handed(walk, index, state, trusted, reach))
                    if may_throw(ir, index) && !isempty(state)
                        destination = catch_block(ir, handlers, index)
                        if destination == 0
                            for (resource, hold) in state
                                resource == target && continue
                                sure = !isnothing(hold.count) && !path.blurred && !(untracked && last(resource) == last(target))
                                fact = (sure ? Confidence.definite : Confidence.possible, index, hold.acquire)
                                old = get(found, resource, nothing)
                                (isnothing(old) || fact[1:2] < old[1:2]) && (found[resource] = fact)
                            end
                        else
                            add_path!(entries[destination], path) && push!(pending, destination)
                        end
                    end
                    isnothing(change) || apply_change!(state, something(change), index)
                    negated = only_operand(walk, index, !)
                    if !isnothing(negated) && haskey(known, something(negated))
                        known[Core.SSAValue(index)] = !known[something(negated)]
                    end
                    tried = try_resource(walk, index)
                    if !isnothing(tried) && forked < PATH_LIMIT
                        forked += 1
                        push!(forks, (Path(copy(state), merge(known, Dict{Any, Bool}(Core.SSAValue(index) => false)), copy(path.dropped), path.blurred), index + 1))
                        known[Core.SSAValue(index)] = true
                        apply_change!(state, something(tried) => 1, index)
                    elseif !isnothing(tried)
                        # Forks past limit: success and failure share path, so count is unknown.
                        apply_change!(state, something(tried) => nothing, index)
                    end
                end
                for (successor, taken) in path_successors(ir, block, path)
                    add_path!(entries[successor], taken) && push!(pending, successor)
                end
            end
        end
    end
    return UnguardedHold[UnguardedHold(spans[acquire], spans[throws], confidence, last(resource)) for (resource, (confidence, throws, acquire)) in found]
end
