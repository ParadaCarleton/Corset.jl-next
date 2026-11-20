"""Effects by origin, whether they cover objects below, and kind at access statement."""
const OriginAccesses = Dict{Tuple{Origin.Type, Bool, EffectKind.T}, Effect}

"""Targets by holder origin, for one slot kind: memory backing or unknown slot."""
const OriginHolds = Dict{Origin.Type, Targets}

"""Callback record during fixpoint: variant and targets of each callee parameter, callable first (`Callback`)."""
const Deferred = Tuple{Variant, Vector{Targets}}

"""
Points-to state of one instance during its fixpoint (`effects.md`, Origins and points-to): call outcome, message flag
(`message_statements`) and release balance primitive (`primitive`) per statement; targets per IR value and argument; type sources each IR value derives from
values that made it (`derived_of`) and of each static parameter; flow-insensitive heap by origin and slot, memory
backing, unknown-slot stores and global bindings; result targets; accesses by origin and whether they cover places
below; callback records by call statement. `changed` records growth of targets in current round; `closed_world` records
join over methods loaded now, and `cut` path stand-ins cut (`Summary`). `flush` resolves every callback record here:
root unit has no caller to resolve them. `record` keeps kinds of writes each call statement makes (`call_kinds`).
`follows` keeps slot targets by origin and step (`load`); `stale` marks heap growth since they were found.
`settled`: round after one that changed nothing, so it applies callee accesses and skips callee stores (`apply!`).
"""
mutable struct Flow
    const ir::CC.IRCode
    const outcomes::Vector{Union{Nothing, Outcome.Type}}
    const message::Vector{Bool}
    const primitives::Vector{Union{Nothing, Primitive}}
    const values::Vector{Targets}
    const derived::Vector{Sources}
    const statics::Vector{Sources}
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
    const record::Bool
    const call_kinds::Dict{Int, Set{EffectKind.T}}
    const follows::Dict{Tuple{Origin.Type, Step.Type}, Targets}
    changed::Bool
    stale::Bool
    settled::Bool
    closed_world::Bool
    cut::Bool
end

"""
Flow of `ir` with call `outcomes` and `message` statements before first round: each referent argument points to its
parameter. `flush` resolves callback records in this instance; `cut` marks instance whose own code stand-ins cut;
`statics` holds sources of each static parameter (`static_sources`); `record` keeps write kinds of each call.
"""
function start_flow(ir::CC.IRCode, outcomes::Vector{Union{Nothing, Outcome.Type}}, message::Vector{Bool}, referent::IdDict{Any, Bool}, flush::Bool, cut::Bool, statics::Vector{Sources}, record::Bool)::Flow
    arguments = [
        referent!(referent, CC.widenconst(type)) ? Targets(Origin.Caller(Place.At(Root.Parameter(position), Step.Type[])) => NO_DOUBT) : Targets()
            for (position, type) in enumerate(ir.argtypes)
    ]
    heap = Dict{Origin.Type, Dict{Step.Type, Targets}}()
    callbacks = Dict{Int, Vector{Deferred}}()
    primitives = Union{Nothing, Primitive}[statement_primitive(ir, index, outcomes[index]) for index in 1:length(ir.stmts)]
    return Flow(ir, outcomes, message, primitives, [Targets() for _ in 1:length(ir.stmts)], zeros(Sources, length(ir.stmts)), statics, arguments, heap, OriginHolds(), OriginHolds(), Dict{GlobalRef, Targets}(), Targets(), OriginAccesses(), OriginAccesses(), callbacks, referent, flush, record, Dict{Int, Set{EffectKind.T}}(), Dict{Tuple{Origin.Type, Step.Type}, Targets}(), false, false, false, false, cut)
end

"""Release balance primitive of statement `index` of `ir` with call `outcome`: dispatched call only (`primitive`)."""
function statement_primitive(ir::CC.IRCode, index::Int, outcome::Union{Nothing, Outcome.Type})::Union{Nothing, Primitive}
    isnothing(outcome) && return nothing
    return @match something(outcome) begin
        Outcome.Dispatch(_, operands) => primitive(ir, operands, ir.stmts[index][:type])
        _ => nothing
    end
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
add none (`trace`, `map_node`), so sources of chain stay.
"""
unknown(doubt::Doubt)::Targets = Targets(Origin.Unknown() => doubt)

"""Root of `place`."""
root_of(place::Place.Type)::Root.Type = @match place begin
    Place.At(root, _) => root
    Place.Deep(root) => root
end

"""
Join `source` into `target`, each doubt raised to at least `doubt`; mark `flow` changed when `target` changes. Return
whether `target` changed.
"""
function join!(flow::Flow, target::Targets, source::Targets, doubt::Doubt = NO_DOUBT)::Bool
    grew = false
    for (origin, flag) in source
        add!(target, origin, most(flag, doubt)) && (grew = true)
    end
    grew && (flow.changed = true)
    return grew
end

"""Targets stored under `key` of `table`, created empty on first use."""
function slot!(table::Dict{K, Targets}, key::K)::Targets where {K}
    return get!(Targets, table, key)
end

"""Targets stored in `step` slot of `origin`; `nothing` for slot without store."""
function slot(flow::Flow, origin::Origin.Type, step::Step.Type)::Union{Nothing, Targets}
    slots = get(flow.heap, origin, nothing)
    return isnothing(slots) ? nothing : get(slots, step, nothing)
end

"""Add each origin of `source` with its doubt raised to at least `doubt` to `found`; `nothing` adds none."""
function add_all!(found::Targets, source::Union{Nothing, Targets}, doubt::Doubt)::Nothing
    isnothing(source) && return nothing
    for (origin, flag) in source
        add!(found, origin, most(flag, doubt))
    end
    return nothing
end

"""Call `visit` on targets of every slot of `origin`: fields, memory backing, then unknown slot."""
function foreach_content(visit::F, flow::Flow, origin::Origin.Type)::Nothing where {F}
    slots = get(flow.heap, origin, nothing)
    isnothing(slots) || foreach(visit, values(slots))
    backing = get(flow.backing, origin, nothing)
    isnothing(backing) || visit(backing)
    spread = get(flow.spread, origin, nothing)
    isnothing(spread) || visit(spread)
    return nothing
end

"""
Origins `objects` hold, through slots of fresh objects: access below fresh object (open call operand, vararg tuple)
reaches caller objects inside it. Without fresh object, result is `objects` itself: callers only read it.
"""
function beneath(flow::Flow, objects::Targets)::Targets
    any(fresh_origin, keys(objects)) || return objects
    found, pending = copy(objects), filter(fresh_origin, collect(keys(objects)))
    seen = Set(pending)
    while !isempty(pending)
        origin = pop!(pending)
        foreach_content(flow, origin) do targets
            for (target, doubt) in targets
                add!(found, target, most(doubt, found[origin]))
                fresh_origin(target) && !(target in seen) && (push!(seen, target); push!(pending, target))
            end
        end
    end
    return found
end

"""Whether `flow` value of `type` can point to object."""
points(flow::Flow, @nospecialize(type::Any))::Bool = referent!(flow.referent, CC.widenconst(type))

"""Whether global `binding` is constant null pointer (`C_NULL`): pointer into no object."""
null_pointer(binding::GlobalRef)::Bool = isconst(binding) && (pointer = getglobal(binding.mod, binding.name); pointer isa Ptr && pointer == C_NULL)

"""Targets of global `binding`: object caller sees there, and objects instance binds to it. Null pointer has none."""
function global_targets(flow::Flow, binding::GlobalRef)::Targets
    null_pointer(binding) && return Targets()
    found = Targets(Origin.Caller(Place.At(Root.Global(binding), Step.Type[])) => NO_DOUBT)
    add_all!(found, get(flow.bound, binding, nothing), NO_DOUBT)
    return found
end

"""Targets of IR `value`: SSA value, argument, global binding, or constant object (unknown)."""
function value_targets(flow::Flow, @nospecialize(value::Any))::Targets
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
function spread_elements(flow::Flow, @nospecialize(value::Any))::Targets
    objects = value_targets(flow, value)
    return value_type(flow.ir, value) <: Tuple ? load_any(flow, objects) : load(flow, objects, Step.Element())
end

"""
Place one `step` below `place` in instance with IR `ir`: exact path while it stays exact (`exact_path`), else `Deep`
of its root. Collapse adds no doubt: object stays below same root (`effects.md`, Origins and points-to).
"""
function extend(ir::CC.IRCode, place::Place.Type, step::Step.Type)::Place.Type
    return @match place begin
        Place.At(root, steps) => (extended = [steps; step]; exact_path(ir, root, extended) ? Place.At(root, extended) : Place.Deep(root))
        Place.Deep(root) => place
    end
end

"""Abstract steps in a row that path keeps: next one collapses it."""
const ABSTRACT_STEPS = 2

"""
Whether path `steps` below `root` in instance with IR `ir` stays exact: path follows declared field types; it collapses
at step into concrete type it already passed (recursive type), at abstract step past `ABSTRACT_STEPS` in a row, or past
`PATH_DEPTH` steps.
"""
function exact_path(ir::CC.IRCode, root::Root.Type, steps::Vector{Step.Type})::Bool
    length(steps) <= PATH_DEPTH || return false
    type, passed, run = root_type(ir, root), Any[], 0
    for step in steps
        isconcretetype(type) && push!(passed, type)
        type = step_type(type, step)
        run = isconcretetype(type) ? 0 : run + 1
        run > ABSTRACT_STEPS && return false
        isconcretetype(type) && type in passed && return false
    end
    return true
end

"""Step of pointer to memory data: object that owns memory shares it with the memory's other owners (`Memory` field `ptr`)."""
const MEMORY_POINTER = Step.Field(:ptr)

"""
Targets of `step` slot of `origin`: place below caller object, stored targets, and element or data pointer of each
memory backing chain reaches, with doubt of chain.
"""
function trace(flow::Flow, origin::Origin.Type, step::Step.Type)::Targets
    found, reached, pending = Targets(), Targets(), [origin => NO_DOUBT]
    while !isempty(pending)
        current, chain = pop!(pending)
        # Walk origin again only when chain lowers its doubt: result does not depend on visit order.
        add!(reached, current, chain) || continue
        doubt = reached[current]
        @match current begin
            Origin.Caller(place) => add!(found, Origin.Caller(extend(flow.ir, place, step)), doubt)
            Origin.Unknown() => add!(found, current, doubt)
            Origin.Allocation(_) => nothing
        end
        add_all!(found, slot(flow, current, step), doubt)
        add_all!(found, get(flow.spread, current, nothing), doubt)
        backing = get(flow.backing, current, nothing)
        ((step == Step.Element() || step == MEMORY_POINTER) && !isnothing(backing)) || continue
        for (memory, flag) in backing
            push!(pending, memory => most(flag, doubt))
        end
    end
    return found
end

"""
Targets of `step` slot over every origin of `objects`. Slot targets of each origin come from `trace` once per heap
state: calls map same places at each call statement and round, and memory backing chains grow long.
"""
function load(flow::Flow, objects::Targets, step::Step.Type)::Targets
    flow.stale && (empty!(flow.follows); flow.stale = false)
    found = Targets()
    for (origin, doubt) in objects, (target, flag) in get!(() -> trace(flow, origin, step), flow.follows, (origin, step))
        add!(found, target, most(flag, doubt))
    end
    return found
end

"""
Targets of any slot of `objects`: caller objects collapse to `Deep`, doubt kept; allocations give every stored slot, through memory
backing too. Serves loads whose slot is not constant. Merged callee objects can back themselves, so walk keeps `seen`.
"""
function load_any(flow::Flow, objects::Targets)::Targets
    found, reached, pending = Targets(), Targets(), collect(objects)
    while !isempty(pending)
        origin, chain = pop!(pending)
        # Walk origin again only when chain lowers its doubt: result does not depend on visit order.
        add!(reached, origin, chain) || continue
        doubt = reached[origin]
        @match origin begin
            Origin.Caller(place) => add!(found, Origin.Caller(Place.Deep(root_of(place))), doubt)
            Origin.Unknown() => add!(found, origin, doubt)
            Origin.Allocation(_) => nothing
        end
        slots = get(flow.heap, origin, nothing)
        if !isnothing(slots)
            for targets in values(slots)
                add_all!(found, targets, doubt)
            end
        end
        add_all!(found, get(flow.spread, origin, nothing), doubt)
        backing = get(flow.backing, origin, nothing)
        if !isnothing(backing)
            for (memory, flag) in backing
                push!(pending, memory => most(flag, doubt))
            end
        end
    end
    return found
end

"""
Record access of `kind` in `table` (writes or reads) on each origin of `objects`. Chain doubt raises effect doubt;
blind chain gives cause `alias` unless effect is blind already.
"""
function access!(table::OriginAccesses, objects::Targets, below::Bool, effect::Effect, kind::EffectKind.T)::Nothing
    for (origin, doubt) in objects
        reason = level_of(effect.doubt) == Level.blind ? effect.reason : level_of(doubt) == Level.blind ? "alias" : ""
        found = Effect(most(effect.doubt, doubt), effect.cause, reason)
        key = (origin, below, kind)
        table[key] = haskey(table, key) ? stronger(table[key], found) : found
    end
    return nothing
end

"""
Store `values` into `step` slot of every origin of `objects`; `nothing` step stores into unknown slot. Growth makes
slot targets `load` found stale.
"""
function store!(flow::Flow, objects::Targets, step::Union{Nothing, Step.Type}, values::Targets)::Nothing
    for (origin, doubt) in objects
        target = isnothing(step) ? slot!(flow.spread, origin) : slot!(get!(Dict{Step.Type, Targets}, flow.heap, origin), step)
        join!(flow, target, values, doubt) && (flow.stale = true)
    end
    return nothing
end

"""Store `values` into memory backing of every origin of `objects`; growth makes slot targets `load` found stale."""
function store_backing!(flow::Flow, objects::Targets, values::Targets)::Nothing
    for (origin, doubt) in objects
        join!(flow, slot!(flow.backing, origin), values, doubt) && (flow.stale = true)
    end
    return nothing
end

"""Bind `values` to global `binding`."""
function bind!(flow::Flow, binding::GlobalRef, values::Targets)::Nothing
    join!(flow, slot!(flow.bound, binding), values)
    return nothing
end

"""Set targets of statement `index` to include `targets`, raised to `doubt`, when its type can point to object."""
function assign!(flow::Flow, index::Int, targets::Targets, doubt::Doubt = NO_DOUBT)::Nothing
    points(flow, flow.ir.stmts[index][:type]) && join!(flow, flow.values[index], targets, doubt)
    return nothing
end

"""
One round over every statement of `flow`, with callee summaries from `callees`. Accesses start empty: last round records
them from settled targets and sources, so code doubt of early round with sources still unknown stays out.
"""
function round!(flow::Flow, callees::Callees)::Nothing
    empty!(flow.writes)
    empty!(flow.reads)
    empty!(flow.call_kinds)
    for index in 1:length(flow.ir.stmts)
        statement!(flow, index, flow.ir.stmts[index][:stmt], callees)
    end
    return nothing
end

"""Expression heads that move no object: control, scope, metadata and coverage markers."""
const INERT = (
    :boundscheck, :pop_exception, :leave, :throw_undef_if_not, :gc_preserve_begin, :gc_preserve_end, :loopinfo, :meta,
    :inbounds, :code_coverage_effect, :isdefined, :aliasscope, :popaliasscope, :undefcheck, :cfunction,
    :latestworld,
)

"""Transfer statement `index` of `flow` (`effects.md`, Calls)."""
function statement!(flow::Flow, index::Int, @nospecialize(statement::Any), callees::Callees)::Nothing
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
        elseif head === :static_parameter
            derive!(flow, index, flow.statics[statement.args[1]::Int])
        elseif !(head in INERT)
            throw(ArgumentError("effects engine has no transfer for IR statement head `$head`"))
        end
    elseif statement isa Core.PhiNode
        for position in eachindex(statement.values)
            isassigned(statement.values, position) && pass!(flow, index, statement.values[position])
        end
    elseif statement isa Core.PhiCNode
        for upsilon in statement.values
            node = flow.ir.stmts[(upsilon::Core.SSAValue).id][:stmt]::Core.UpsilonNode
            isdefined(node, :val) && pass!(flow, index, node.val)
        end
    elseif statement isa Core.PiNode
        pass!(flow, index, statement.val)
    elseif statement isa Core.ReturnNode
        isdefined(statement, :val) && join!(flow, flow.result, value_targets(flow, statement.val))
    elseif statement isa GlobalRef
        isconst(statement) || access!(flow.reads, global_targets(flow, statement), false, definite(index), EffectKind.memory)
        assign!(flow, index, value_targets(flow, statement))
    elseif !(statement isa Union{Nothing, Core.GotoNode, Core.GotoIfNot, Core.EnterNode, Core.UpsilonNode})
        throw(ArgumentError("effects engine has no transfer for IR statement of type `$(typeof(statement))`"))
    end
    return nothing
end

"""Pass IR `value` to statement `index` (phi or pi node): its targets and derived type sources."""
function pass!(flow::Flow, index::Int, @nospecialize(value::Any))::Nothing
    assign!(flow, index, value_targets(flow, value))
    derive!(flow, index, value_derived(flow, value))
    return nothing
end

"""Add `sources` to derived type sources of statement `index`; mark `flow` changed when they grow."""
function derive!(flow::Flow, index::Int, sources::Sources)::Nothing
    grown = flow.derived[index] | sources
    grown == flow.derived[index] && return nothing
    flow.derived[index], flow.changed = grown, true
    return nothing
end

"""
Type sources IR `value` derives without object (`effects.md`, Provenance): sources of call or phi that made SSA value;
parameter source of argument, since caller chose its type.
"""
function value_derived(flow::Flow, @nospecialize(value::Any))::Sources
    value isa Core.SSAValue && return flow.derived[value.id]
    value isa Core.Argument && return parameter_source(value.n)
    return Sources(0)
end

"""
Parameter sources of each static parameter of `method` (`effects.md`, Provenance): every parameter whose declared type
holds its type variable, since caller chose that type.
"""
function static_sources(method::Method)::Vector{Sources}
    signature, variables = method.sig, TypeVar[]
    while signature isa UnionAll
        push!(variables, signature.var)
        signature = signature.body
    end
    sources = zeros(Sources, length(variables))
    for (position, type) in enumerate((signature::DataType).parameters), (at, variable) in enumerate(variables)
        CC.has_typevar(type, variable) && (sources[at] |= parameter_source(position))
    end
    return sources
end

"""Derived type sources of call `operand` (`value_derived`): spread part and elements take sources of spread value."""
derived_of(flow::Flow, operand::Operand.Type)::Sources = @match operand begin
    Operand.Value(value) => value_derived(flow, value)
    Operand.Part(value, _) => value_derived(flow, value)
    Operand.Rest(value) => value_derived(flow, value)
end

"""Make statement `index` an allocation: its value points to fresh object `Allocation(index)`."""
function allocate!(flow::Flow, index::Int)::Nothing
    assign!(flow, index, Targets(Origin.Allocation(index) => NO_DOUBT))
    return nothing
end

"""Allocation of `%new(type, operands...)` at `index`: each operand goes into its field, memory fields into backing."""
function new!(flow::Flow, index::Int, @nospecialize(type_value::Any), operands::Vector{Operand.Type})::Nothing
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

"""
Struct type that gives fields of object of `type`: concrete `type`, or body of array stand-in or `Array` family
(`ArrayStandIn{<:Any, 1}` and its `Vector` data). `nothing` for other type.
Code struct family keeps `Position` steps: its field paths multiply places to map at each call.
"""
function layout(@nospecialize(type::Any))::Union{Nothing, DataType}
    isconcretetype(type) && return type
    type isa UnionAll || return nothing
    array_stand_in(type) || type <: Array || return nothing
    body = Base.unwrap_unionall(type)
    return body isa DataType ? body : nothing
end

"""Whether field `field` of `type` holds memory backing (`GenericMemory` or `GenericMemoryRef`): it adds no path step."""
function backing_field(@nospecialize(type::Any), field::Union{Symbol, Int})::Bool
    type = layout(type)
    isnothing(type) && return false
    type <: Tuple && return false
    field isa Symbol && !hasfield(type, field) && return false
    field isa Int && !(1 <= field <= fieldcount(type)) && return false
    return fieldtype(type, field) <: Union{GenericMemory, GenericMemoryRef}
end

"""
Step for constant field `field` of object of `type`: tuple `Position`, else named `Field` (index becomes name when type
is concrete). `nothing` for field that is not constant.
"""
function field_step(@nospecialize(type::Any), @nospecialize(field::Any))::Union{Nothing, Step.Type}
    if type isa DataType && type <: Tuple
        return field isa Int ? Step.Position(field) : nothing
    end
    field isa Symbol && return Step.Field(field)
    field isa Int || return nothing
    fields = layout(type)
    isnothing(fields) && return Step.Position(field)
    return 1 <= field <= fieldcount(fields) ? Step.Field(fieldname(fields, field)) : Step.Position(field)
end

"""Definite effect starting at statement `index`."""
definite(index::Int)::Effect = Effect(NO_DOUBT, index, "")
