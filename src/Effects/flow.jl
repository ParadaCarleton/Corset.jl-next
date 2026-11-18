"""Effects by origin and whether they cover objects below."""
const OriginAccesses = Dict{Tuple{Origin.Type, Bool}, Effect}

"""Targets by holder origin, for one slot kind: memory backing or unknown slot."""
const OriginHolds = Dict{Origin.Type, Targets}

"""Callback record during fixpoint: variant and targets of each callee parameter, callable first (`Callback`)."""
const Deferred = Tuple{Variant, Vector{Targets}}

"""
Points-to state of one instance during its fixpoint (`effects.md`, Origins and points-to): targets per IR value and
argument; flow-insensitive heap by origin and slot, memory backing, unknown-slot stores and global bindings; result
targets; accesses by origin and whether they cover places below; callback records by call statement. `changed` records
growth of targets in current round; `closed_world` records join over methods loaded now, and `cut` path stand-ins cut
(`Summary`). `flush` resolves every callback record here: root unit has no caller to resolve them.
"""
mutable struct Flow
    const ir::CC.IRCode
    const outcomes::Vector{Union{Nothing, Outcome.Type}}
    const values::Vector{Targets}
    const arguments::Vector{Targets}
    const heap::Dict{Origin.Type, Dict{Step.Type, Targets}}
    const backing::OriginHolds
    const spread::OriginHolds
    const bound::Dict{GlobalRef, Targets}
    const result::Targets
    const writes::OriginAccesses
    const reads::OriginAccesses
    const callbacks::Dict{Int, Vector{Deferred}}
    const referent::IdDict{Any, Bool}
    const flush::Bool
    changed::Bool
    closed_world::Bool
    cut::Bool
end

"""
Flow of `ir` with call `outcomes` before first round: each referent argument points to its parameter. `flush` resolves
callback records in this instance; `cut` marks instance whose own code stand-ins cut (`Flow`).
"""
function start_flow(ir::CC.IRCode, outcomes::Vector{Union{Nothing, Outcome.Type}}, referent::IdDict{Any, Bool}, flush::Bool, cut::Bool)::Flow
    arguments = [
        referent!(referent, CC.widenconst(type)) ? Targets(Origin.Caller(Place.At(Root.Parameter(position), Step.Type[])) => NO_DOUBT) : Targets()
            for (position, type) in enumerate(ir.argtypes)
    ]
    heap = Dict{Origin.Type, Dict{Step.Type, Targets}}()
    callbacks = Dict{Int, Vector{Deferred}}()
    return Flow(ir, outcomes, [Targets() for _ in 1:length(ir.stmts)], arguments, heap, OriginHolds(), OriginHolds(), Dict{GlobalRef, Targets}(), Targets(), OriginAccesses(), OriginAccesses(), callbacks, referent, flush, false, false, cut)
end

"""
Callee summaries for one instance solve: variants each call statement reaches, one per matching method; summaries by
variant; and variants whose summaries solve read, so call cycle reruns readers when they change.
"""
struct Callees
    variants::Vector{Vector{Variant}}
    summaries::Dict{Variant, Summary}
    read::Set{Variant}
end

"""Summary of `variant` from `callees`, recorded as read."""
function summary!(callees::Callees, variant::Variant)::Summary
    push!(callees.read, variant)
    return callees.summaries[variant]
end

"""Add `origin` with `doubt` to `targets`; chain with less doubt wins (`least`). Return whether `targets` changed."""
function add!(targets::Targets, origin::Origin.Type, doubt::Doubt)::Bool
    old = get(targets, origin, nothing)
    new = isnothing(old) ? doubt : least(old, doubt)
    new == old && return false
    targets[origin] = new
    return true
end

"""Union of `parts`, least doubt per origin."""
function union_targets(parts::Any)::Targets
    found = Targets()
    for part in parts, (origin, doubt) in part
        add!(found, origin, doubt)
    end
    return found
end

"""Targets of `targets` with each doubt raised to at least `doubt`."""
raised(targets::Targets, doubt::Doubt)::Targets = Targets(origin => most(flag, doubt) for (origin, flag) in targets)

"""
Unknown object with chain `doubt`. Engine reaches it with `code` doubt or more: steps from it and callee nodes for it
add none (`follow`, `map_node`), so sources of chain stay.
"""
unknown(doubt::Doubt)::Targets = Targets(Origin.Unknown() => doubt)

"""Root of `place`."""
root_of(place::Place.Type)::Root.Type = @match place begin
    Place.At(root, _) => root
    Place.Deep(root) => root
end

"""Join `source` into `target`, each doubt raised to at least `doubt`; mark `flow` changed when `target` changes."""
function join!(flow::Flow, target::Targets, source::Targets, doubt::Doubt = NO_DOUBT)::Nothing
    for (origin, flag) in source
        add!(target, origin, most(flag, doubt)) && (flow.changed = true)
    end
    return nothing
end

"""Targets stored under `key` of `table`, created empty on first use."""
function slot!(table::Dict{K, Targets}, key::K)::Targets where {K}
    return get!(Targets, table, key)
end

"""Targets stored in `step` slot of `origin`."""
function slot(flow::Flow, origin::Origin.Type, step::Step.Type)::Targets
    slots = get(flow.heap, origin, nothing)
    return isnothing(slots) ? Targets() : get(slots, step, Targets())
end

"""Targets in every slot of `origin`: fields, memory backing and unknown slot."""
function contents(flow::Flow, origin::Origin.Type)::Vector{Targets}
    slots = get(flow.heap, origin, nothing)
    return [isnothing(slots) ? Targets[] : collect(values(slots)); get(flow.backing, origin, Targets()); get(flow.spread, origin, Targets())]
end

"""
Origins `objects` hold, through slots of fresh objects: access below fresh object (open call operand, vararg tuple)
reaches caller objects inside it.
"""
function beneath(flow::Flow, objects::Targets)::Targets
    found, pending = copy(objects), filter(fresh_origin, collect(keys(objects)))
    seen = Set(pending)
    while !isempty(pending)
        origin = pop!(pending)
        for targets in contents(flow, origin), (target, doubt) in targets
            add!(found, target, most(doubt, found[origin]))
            fresh_origin(target) && !(target in seen) && (push!(seen, target); push!(pending, target))
        end
    end
    return found
end

"""Whether `flow` value of `type` can point to object."""
points(flow::Flow, type::Any)::Bool = referent!(flow.referent, CC.widenconst(type))

"""Whether global `binding` is constant null pointer (`C_NULL`): pointer into no object."""
null_pointer(binding::GlobalRef)::Bool = isconst(binding) && (pointer = getglobal(binding.mod, binding.name); pointer isa Ptr && pointer == C_NULL)

"""Targets of global `binding`: object caller sees there, and objects instance binds to it. Null pointer has none."""
function global_targets(flow::Flow, binding::GlobalRef)::Targets
    null_pointer(binding) && return Targets()
    return union_targets((Targets(Origin.Caller(Place.At(Root.Global(binding), Step.Type[])) => NO_DOUBT), get(flow.bound, binding, Targets())))
end

"""Targets of IR `value`: SSA value, argument, global binding, or constant object (unknown)."""
function value_targets(flow::Flow, value::Any)::Targets
    value isa Core.SSAValue && return flow.values[value.id]
    value isa Core.Argument && return flow.arguments[value.n]
    points(flow, CC.argextype(value, flow.ir)) || return Targets()
    value isa GlobalRef && return global_targets(flow, value)
    return unknown(CODE_DOUBT)
end

"""Targets of call `operand`: value, slot at position of spread tuple, or every element of `Rest`."""
function operand_targets(flow::Flow, operand::Operand.Type)::Targets
    return @match operand begin
        Operand.Value(value) => value_targets(flow, value)
        Operand.Part(value, position) => load(flow, value_targets(flow, value), Step.Position(position))
        Operand.Rest(value) => spread_elements(flow, value)
    end
end

"""Targets of every element of spread tuple or array `value`: tuple position is unknown, so any slot (`load_any`)."""
function spread_elements(flow::Flow, value::Any)::Targets
    objects = value_targets(flow, value)
    return value_type(flow.ir, value) <: Tuple ? load_any(flow, objects) : load(flow, objects, Step.Element())
end

"""Place one `step` below `place`, and doubt step adds: past `PATH_DEPTH` steps path collapses to `Deep` (blind)."""
function extend(place::Place.Type, step::Step.Type)::Tuple{Place.Type, Doubt}
    return @match place begin
        Place.At(root, steps) => length(steps) < PATH_DEPTH ? (Place.At(root, [steps; step]), NO_DOUBT) : (Place.Deep(root), BLIND_DOUBT)
        Place.Deep(root) => (Place.Deep(root), BLIND_DOUBT)
    end
end

"""Targets of `step` slot of `origin`: place below caller object, stored targets, and element of memory backing."""
function follow(flow::Flow, origin::Origin.Type, step::Step.Type, seen::Set{Origin.Type} = Set{Origin.Type}())::Targets
    found = Targets()
    push!(seen, origin)
    @match origin begin
        Origin.Caller(place) => add!(found, Origin.Caller(first(extend(place, step))), last(extend(place, step)))
        Origin.Unknown() => add!(found, origin, NO_DOUBT)
        Origin.Allocation(_) => nothing
    end
    for source in (slot(flow, origin, step), get(flow.spread, origin, Targets())), (target, doubt) in source
        add!(found, target, doubt)
    end
    step == Step.Element() || return found
    for (memory, doubt) in get(flow.backing, origin, Targets())
        memory in seen && continue
        for (target, flag) in follow(flow, memory, step, seen)
            add!(found, target, most(flag, doubt))
        end
    end
    return found
end

"""Targets of `step` slot over every origin of `objects`."""
function load(flow::Flow, objects::Targets, step::Step.Type)::Targets
    found = Targets()
    for (origin, doubt) in objects, (target, flag) in follow(flow, origin, step)
        add!(found, target, most(flag, doubt))
    end
    return found
end

"""
Targets of any slot of `objects`: caller objects collapse to `Deep`; allocations give every stored slot, through memory
backing too. Serves loads whose slot is not constant. Merged callee objects can back themselves, so walk keeps `seen`.
"""
function load_any(flow::Flow, objects::Targets)::Targets
    found, pending, seen = Targets(), collect(objects), Set{Origin.Type}()
    while !isempty(pending)
        origin, doubt = pop!(pending)
        origin in seen && continue
        push!(seen, origin)
        @match origin begin
            Origin.Caller(place) => add!(found, Origin.Caller(Place.Deep(root_of(place))), BLIND_DOUBT)
            Origin.Unknown() => add!(found, origin, doubt)
            Origin.Allocation(_) => nothing
        end
        slots = get(flow.heap, origin, Dict{Step.Type, Targets}())
        for targets in [collect(values(slots)); get(flow.spread, origin, Targets())], (target, flag) in targets
            add!(found, target, most(flag, doubt))
        end
        for (memory, flag) in get(flow.backing, origin, Targets())
            push!(pending, memory => most(flag, doubt))
        end
    end
    return found
end

"""
Record access in `table` (writes or reads) on each origin of `objects`. Chain doubt raises effect doubt; blind chain
gives cause `alias` unless effect is blind already.
"""
function access!(table::OriginAccesses, objects::Targets, below::Bool, effect::Effect)::Nothing
    for (origin, doubt) in objects
        reason = level_of(effect.doubt) == Level.blind ? effect.reason : level_of(doubt) == Level.blind ? "alias" : ""
        found = Effect(most(effect.doubt, doubt), effect.cause, reason)
        key = (origin, below)
        table[key] = haskey(table, key) ? stronger(table[key], found) : found
    end
    return nothing
end

"""Store `values` into `step` slot of every origin of `objects`; `nothing` step stores into unknown slot."""
function store!(flow::Flow, objects::Targets, step::Union{Nothing, Step.Type}, values::Targets)::Nothing
    for (origin, doubt) in objects
        join!(flow, isnothing(step) ? slot!(flow.spread, origin) : slot!(get!(Dict{Step.Type, Targets}, flow.heap, origin), step), values, doubt)
    end
    return nothing
end

"""Store `values` into memory backing of every origin of `objects`."""
function store_backing!(flow::Flow, objects::Targets, values::Targets)::Nothing
    foreach(((origin, doubt),) -> join!(flow, slot!(flow.backing, origin), values, doubt), objects)
    return nothing
end

"""Bind `values` to global `binding`."""
bind!(flow::Flow, binding::GlobalRef, values::Targets)::Nothing = join!(flow, slot!(flow.bound, binding), values)

"""Set targets of statement `index` to include `targets`, raised to `doubt`, when its type can point to object."""
function assign!(flow::Flow, index::Int, targets::Targets, doubt::Doubt = NO_DOUBT)::Nothing
    points(flow, flow.ir.stmts[index][:type]) && join!(flow, flow.values[index], targets, doubt)
    return nothing
end

"""One round over every statement of `flow`, with callee summaries from `callees`."""
function round!(flow::Flow, callees::Callees)::Nothing
    for index in 1:length(flow.ir.stmts)
        statement!(flow, index, flow.ir.stmts[index][:stmt], callees)
    end
    return nothing
end

"""Expression heads that move no object: control, scope, metadata and coverage markers."""
const INERT = (
    :boundscheck, :pop_exception, :leave, :throw_undef_if_not, :gc_preserve_begin, :gc_preserve_end, :loopinfo, :meta,
    :inbounds, :code_coverage_effect, :isdefined, :static_parameter, :aliasscope, :popaliasscope, :undefcheck, :cfunction,
    :latestworld,
)

"""Transfer statement `index` of `flow` (`effects.md`, Calls)."""
function statement!(flow::Flow, index::Int, statement::Any, callees::Callees)::Nothing
    if statement isa Expr
        head = statement.head
        if head in (:call, :foreigncall)
            call!(flow, index, something(flow.outcomes[index]), callees)
        elseif head === :new
            new!(flow, index, statement.args[1], Operand.Type[Operand.Value(value) for value in statement.args[2:end]])
        elseif head === :splatnew
            type = value_type(flow.ir, statement.args[2])
            if definite_tuple(type)
                new!(flow, index, statement.args[1], Operand.Type[Operand.Part(statement.args[2], position) for position in 1:fieldcount(type)])
            else
                # Field count unknown: any field may hold any slot of tuple.
                allocate!(flow, index)
                store!(flow, flow.values[index], nothing, load_any(flow, value_targets(flow, statement.args[2])))
            end
        elseif head === :new_opaque_closure || head === :copyast
            allocate!(flow, index)
            store!(flow, flow.values[index], nothing, union_targets(value_targets(flow, value) for value in statement.args))
        elseif head === :the_exception
            assign!(flow, index, unknown(CODE_DOUBT))
        elseif !(head in INERT)
            throw(ArgumentError("effects engine has no transfer for IR statement head `$head`"))
        end
    elseif statement isa Core.PhiNode
        for position in eachindex(statement.values)
            isassigned(statement.values, position) && assign!(flow, index, value_targets(flow, statement.values[position]))
        end
    elseif statement isa Core.PhiCNode
        for upsilon in statement.values
            node = flow.ir.stmts[(upsilon::Core.SSAValue).id][:stmt]::Core.UpsilonNode
            isdefined(node, :val) && assign!(flow, index, value_targets(flow, node.val))
        end
    elseif statement isa Core.PiNode
        assign!(flow, index, value_targets(flow, statement.val))
    elseif statement isa Core.ReturnNode
        isdefined(statement, :val) && join!(flow, flow.result, value_targets(flow, statement.val))
    elseif statement isa GlobalRef
        isconst(statement) || access!(flow.reads, global_targets(flow, statement), false, definite(index))
        assign!(flow, index, value_targets(flow, statement))
    elseif !(statement isa Union{Nothing, Core.GotoNode, Core.GotoIfNot, Core.EnterNode, Core.UpsilonNode})
        throw(ArgumentError("effects engine has no transfer for IR statement of type `$(typeof(statement))`"))
    end
    return nothing
end

"""Make statement `index` an allocation: its value points to fresh object `Allocation(index)`."""
function allocate!(flow::Flow, index::Int)::Nothing
    assign!(flow, index, Targets(Origin.Allocation(index) => NO_DOUBT))
    return nothing
end

"""Allocation of `%new(type, operands...)` at `index`: each operand goes into its field, memory fields into backing."""
function new!(flow::Flow, index::Int, type_value::Any, operands::Vector{Operand.Type})::Nothing
    allocate!(flow, index)
    type = CC.instanceof_tfunc(CC.argextype(type_value, flow.ir))[1]
    object = flow.values[index]
    for (position, operand) in enumerate(operands)
        targets = operand_targets(flow, operand)
        isempty(targets) && continue
        if backing_field(type, position)
            store_backing!(flow, object, targets)
        else
            store!(flow, object, field_step(type, position), targets)
        end
    end
    return nothing
end

"""Whether field `field` of `type` holds memory backing (`GenericMemory` or `GenericMemoryRef`): it adds no path step."""
function backing_field(type::Any, field::Union{Symbol, Int})::Bool
    type isa DataType || return false
    isconcretetype(type) && !(type <: Tuple) || return false
    field isa Symbol && !hasfield(type, field) && return false
    field isa Int && !(1 <= field <= fieldcount(type)) && return false
    return fieldtype(type, field) <: Union{GenericMemory, GenericMemoryRef}
end

"""
Step for constant field `field` of object of `type`: tuple `Position`, else named `Field` (index becomes name when type
is concrete). `nothing` for field that is not constant.
"""
function field_step(type::Any, field::Any)::Union{Nothing, Step.Type}
    if type isa DataType && type <: Tuple
        return field isa Int ? Step.Position(field) : nothing
    end
    field isa Symbol && return Step.Field(field)
    field isa Int || return nothing
    type isa DataType || return Step.Position(field)
    named = isconcretetype(type) && 1 <= field <= fieldcount(type)
    return named ? Step.Field(fieldname(type, field)) : Step.Position(field)
end

"""Definite effect starting at statement `index`."""
definite(index::Int)::Effect = Effect(NO_DOUBT, index, "")
