"""
Points-to state of one instance during its fixpoint (`effects.md`, Origins and points-to): targets per IR value and
argument; flow-insensitive heap by origin and slot, memory backing, unknown-slot stores and global bindings; result
targets; accesses by origin and whether they cover places below. `changed` records growth of targets in current round.
"""
mutable struct Flow
    const ir::CC.IRCode
    const outcomes::Vector{Union{Nothing, Outcome.Type}}
    const values::Vector{Targets}
    const arguments::Vector{Targets}
    const heap::Dict{Tuple{Origin.Type, Step.Type}, Targets}
    const backing::Dict{Origin.Type, Targets}
    const spread::Dict{Origin.Type, Targets}
    const bound::Dict{GlobalRef, Targets}
    const result::Targets
    const writes::Dict{Tuple{Origin.Type, Bool}, Effect}
    const reads::Dict{Tuple{Origin.Type, Bool}, Effect}
    const referent::IdDict{Any, Bool}
    changed::Bool
end

"""Flow of `ir` with call `outcomes` before first round: each referent argument points to its parameter."""
function start_flow(ir::CC.IRCode, outcomes::Vector{Union{Nothing, Outcome.Type}}, referent::IdDict{Any, Bool})::Flow
    arguments = [
        referent!(referent, CC.widenconst(type)) ? Targets(Origin.Caller(Place.At(Root.Parameter(position), Step.Type[])) => Doubt.none) : Targets()
            for (position, type) in enumerate(ir.argtypes)
    ]
    return Flow(ir, outcomes, [Targets() for _ in 1:length(ir.stmts)], arguments, Dict(), Dict(), Dict(), Dict(), Targets(), Dict(), Dict(), referent, false)
end

"""Add `origin` with `doubt` to `targets`; chain with less doubt wins. Return whether `targets` changed."""
function add!(targets::Targets, origin::Origin.Type, doubt::Doubt.T)::Bool
    old = get(targets, origin, nothing)
    isnothing(old) || doubt < old || return false
    targets[origin] = doubt
    return true
end

"""Union of `parts`, least doubt per origin."""
function union_targets(parts)::Targets
    found = Targets()
    for part in parts, (origin, doubt) in part
        add!(found, origin, doubt)
    end
    return found
end

"""Targets of `targets` with each doubt raised to at least `doubt`."""
raised(targets::Targets, doubt::Doubt.T)::Targets = Targets(origin => most(flag, doubt) for (origin, flag) in targets)

"""Unknown object, reached through open call."""
unknown()::Targets = Targets(Origin.Unknown() => Doubt.code)

"""Root of `place`."""
root_of(place::Place.Type)::Root.Type = @match place begin
    Place.At(root, _) => root
    Place.Deep(root) => root
end

"""Join `source` into `target`, each doubt raised to at least `doubt`; mark `flow` changed when `target` changes."""
function join!(flow::Flow, target::Targets, source::Targets, doubt::Doubt.T = Doubt.none)::Nothing
    for (origin, flag) in source
        add!(target, origin, most(flag, doubt)) && (flow.changed = true)
    end
    return nothing
end

"""Targets stored under `key` of `table`, created empty on first use."""
slot!(table::Dict{K, Targets}, key::K) where {K} = get!(Targets, table, key)

"""Whether `flow` value of `type` can point to object."""
points(flow::Flow, type::Any)::Bool = referent!(flow.referent, CC.widenconst(type))

"""Targets of global `binding`: object caller sees there, and objects instance binds to it."""
global_targets(flow::Flow, binding::GlobalRef)::Targets = union_targets((Targets(Origin.Caller(Place.At(Root.Global(binding), Step.Type[])) => Doubt.none), get(flow.bound, binding, Targets())))

"""Targets of IR `value`: SSA value, argument, global binding, or constant object (unknown)."""
function value_targets(flow::Flow, value::Any)::Targets
    value isa Core.SSAValue && return flow.values[value.id]
    value isa Core.Argument && return flow.arguments[value.n]
    points(flow, CC.argextype(value, flow.ir)) || return Targets()
    value isa GlobalRef && return global_targets(flow, value)
    return unknown()
end

"""Targets of call `operand`: value, or slot at position of spread tuple."""
function operand_targets(flow::Flow, operand::Operand.Type)::Targets
    return @match operand begin
        Operand.Value(value) => value_targets(flow, value)
        Operand.Part(value, position) => load(flow, value_targets(flow, value), Step.Position(position))
    end
end

"""Place one `step` below `place`, and doubt step adds: past `PATH_DEPTH` steps path collapses to `Deep` (blind)."""
function extend(place::Place.Type, step::Step.Type)::Tuple{Place.Type, Doubt.T}
    return @match place begin
        Place.At(root, steps) => length(steps) < PATH_DEPTH ? (Place.At(root, [steps; step]), Doubt.none) : (Place.Deep(root), Doubt.blind)
        Place.Deep(root) => (Place.Deep(root), Doubt.blind)
    end
end

"""Targets of `step` slot of `origin`: place below caller object, stored targets, and element of memory backing."""
function follow(flow::Flow, origin::Origin.Type, step::Step.Type, seen::Set{Origin.Type} = Set{Origin.Type}())::Targets
    found = Targets()
    push!(seen, origin)
    @match origin begin
        Origin.Caller(place) => add!(found, Origin.Caller(first(extend(place, step))), last(extend(place, step)))
        Origin.Unknown() => add!(found, origin, Doubt.code)
        Origin.Allocation(_) => nothing
    end
    for source in (get(flow.heap, (origin, step), Targets()), get(flow.spread, origin, Targets()))
        foreach(((target, doubt),) -> add!(found, target, doubt), source)
    end
    if step == Step.Element()
        for (memory, doubt) in get(flow.backing, origin, Targets())
            memory in seen && continue
            foreach(((target, flag),) -> add!(found, target, most(flag, doubt)), follow(flow, memory, step, seen))
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
Targets of any slot of `objects`: caller objects collapse to `Deep`; allocations give every stored slot. Serves loads
whose slot is not constant.
"""
function load_any(flow::Flow, objects::Targets)::Targets
    found = Targets()
    for (origin, doubt) in objects
        @match origin begin
            Origin.Caller(place) => add!(found, Origin.Caller(Place.Deep(root_of(place))), Doubt.blind)
            Origin.Unknown() => add!(found, origin, Doubt.code)
            Origin.Allocation(_) => nothing
        end
        for ((holder, _), targets) in flow.heap
            holder == origin && foreach(((target, flag),) -> add!(found, target, most(flag, doubt)), targets)
        end
        foreach(((target, flag),) -> add!(found, target, most(flag, doubt)), get(flow.spread, origin, Targets()))
        for (memory, flag) in get(flow.backing, origin, Targets())
            foreach(((target, inner),) -> add!(found, target, most(inner, flag, doubt)), load_any(flow, Targets(memory => Doubt.none)))
        end
    end
    return found
end

"""
Record access in `table` (writes or reads) on each origin of `objects`. Chain doubt raises effect doubt; blind chain
gives cause `alias` unless effect is blind already.
"""
function access!(table::Dict{Tuple{Origin.Type, Bool}, Effect}, objects::Targets, below::Bool, effect::Effect)::Nothing
    for (origin, doubt) in objects
        reason = effect.doubt == Doubt.blind ? effect.reason : doubt == Doubt.blind ? "alias" : ""
        found = Effect(most(effect.doubt, doubt), effect.cause, reason)
        key = (origin, below)
        table[key] = haskey(table, key) ? stronger(table[key], found) : found
    end
    return nothing
end

"""Store `values` into `step` slot of every origin of `objects`; `nothing` step stores into unknown slot."""
function store!(flow::Flow, objects::Targets, step::Union{Nothing, Step.Type}, values::Targets)::Nothing
    for (origin, doubt) in objects
        join!(flow, isnothing(step) ? slot!(flow.spread, origin) : slot!(flow.heap, (origin, step)), values, doubt)
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
function assign!(flow::Flow, index::Int, targets::Targets, doubt::Doubt.T = Doubt.none)::Nothing
    points(flow, flow.ir.stmts[index][:type]) && join!(flow, flow.values[index], targets, doubt)
    return nothing
end

"""One round over every statement of `flow`, with callee summaries from `summary_of`."""
function round!(flow::Flow, summary_of::Function)::Nothing
    for index in 1:length(flow.ir.stmts)
        statement!(flow, index, flow.ir.stmts[index][:stmt], summary_of)
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
function statement!(flow::Flow, index::Int, statement::Any, summary_of::Function)::Nothing
    if statement isa Expr
        head = statement.head
        if head in (:call, :invoke, :foreigncall)
            call!(flow, index, something(flow.outcomes[index]), summary_of)
        elseif head === :new
            new!(flow, index, statement.args[1], Operand.Type[Operand.Value(value) for value in statement.args[2:end]])
        elseif head === :splatnew
            type = value_type(flow.ir, statement.args[2])
            count = type isa DataType && type <: Tuple ? fieldcount(type) : 0
            new!(flow, index, statement.args[1], Operand.Type[Operand.Part(statement.args[2], position) for position in 1:count])
        elseif head === :new_opaque_closure || head === :copyast
            allocate!(flow, index)
            store!(flow, flow.values[index], nothing, union_targets(value_targets(flow, value) for value in statement.args))
        elseif head === :the_exception
            assign!(flow, index, unknown())
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
        assign!(flow, index, value_targets(flow, statement))
    end
    return nothing
end

"""Make statement `index` an allocation: its value points to fresh object `Allocation(index)`."""
function allocate!(flow::Flow, index::Int)::Nothing
    assign!(flow, index, Targets(Origin.Allocation(index) => Doubt.none))
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
    type isa DataType && isconcretetype(type) && !(type <: Tuple) || return false
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
    named = type isa DataType && isconcretetype(type) && 1 <= field <= fieldcount(type)
    return named ? Step.Field(fieldname(type, field)) : Step.Position(field)
end

"""Definite effect starting at statement `index`."""
definite(index::Int)::Effect = Effect(Doubt.none, index, "")
