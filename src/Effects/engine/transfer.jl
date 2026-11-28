using ..Effects: IO_FUNCTIONS, stream_positions

"""Builtins that move no object: tests, type queries, throws and no-op markers."""
const INERT_BUILTINS = (
    Core.isa, Core.:(===), Core.typeof, Core.:(<:), Core.nfields, Core.sizeof, Core.fieldtype, Core.apply_type,
    Core.isdefined, Core.throw, Core.throw_methoderror, Core.donotdelete, Core.applicable, Core._typevar, Core._svec_len,
    Core._compute_sparams, Core.get_binding_type, Core.isdefinedglobal, Core.memoryrefoffset,
)

"""
Result of builtin that writes slot: `stored` value, `object` operand, `old` content, `pair` of old and new content
(`modify`), `replaced` named tuple `(; old, success)`, or `flag` (`Bool`).
"""
@enumx Returns stored object old pair replaced flag

"""Builtin that writes slot: operand position of stored value, of `modify` operator (0 without one), and result."""
struct Shape
    stored::Int
    operator::Int
    returns::Returns.T
end

"""Builtins that write object field."""
const FIELD_WRITES = IdDict{Any, Shape}(
    Core.setfield! => Shape(3, 0, Returns.stored), Core.setfieldonce! => Shape(3, 0, Returns.flag),
    Core.swapfield! => Shape(3, 0, Returns.old), Core.modifyfield! => Shape(4, 3, Returns.pair),
    Core.replacefield! => Shape(4, 0, Returns.replaced),
)

"""Builtins that write global binding."""
const GLOBAL_WRITES = IdDict{Any, Shape}(
    Core.setglobal! => Shape(3, 0, Returns.stored), Core.setglobalonce! => Shape(3, 0, Returns.flag),
    Core.swapglobal! => Shape(3, 0, Returns.old), Core.modifyglobal! => Shape(4, 3, Returns.pair),
    Core.replaceglobal! => Shape(4, 0, Returns.replaced),
)

"""Builtins and intrinsics that write memory element or pointer target."""
const ELEMENT_WRITES = IdDict{Any, Shape}(
    Core.memoryrefset! => Shape(2, 0, Returns.stored), Core.memoryrefsetonce! => Shape(2, 0, Returns.flag),
    Core.memoryrefswap! => Shape(2, 0, Returns.old), Core.memoryrefmodify! => Shape(3, 2, Returns.pair),
    Core.memoryrefreplace! => Shape(3, 0, Returns.replaced),
    Core.Intrinsics.pointerset => Shape(2, 0, Returns.object), Core.Intrinsics.atomic_pointerset => Shape(2, 0, Returns.object),
    Core.Intrinsics.atomic_pointerswap => Shape(2, 0, Returns.old), Core.Intrinsics.atomic_pointermodify => Shape(3, 2, Returns.pair),
    Core.Intrinsics.atomic_pointerreplace => Shape(3, 0, Returns.replaced),
)

"""
Transfer call statement `index` by its `outcome`, with callee variants and summaries from `callees`. Callback records of
previous round at `index` give way to this round. Message call (`message_statements`) adds definite writes only
(`engine.md`, Effect kinds): its writes go into scratch table, and it resolves callback records here. Lock or semaphore
primitive (`primitive`) skips callee body; its result is unknown object. Flow that records call kinds (`Flow`) sends
writes through scratch table too.
"""
function call!(flow::Flow, index::Integer, outcome::Outcome.Type, callees::Callees)::Nothing
    delete!(flow.callbacks, index)
    derive_call!(flow, index, outcome_operands(outcome))
    skipped = flow.primitives[index]
    if !isnothing(skipped) && skipped.skips
        flow.record && (flow.call_kinds[index] = Set([EffectKind.synchronization]))
        # Lock body moves scheduler state only; release balance counts its hold.
        return assign!(flow, index, unknown(CODE_DOUBT))
    end
    message = flow.message[index]
    writes = message || flow.record ? OriginAccesses() : flow.writes
    @match outcome begin
        Outcome.Builtin(builtin, operands) => builtin!(flow, writes, index, builtin, operands)
        Outcome.Intrinsic(intrinsic, operands) => intrinsic!(flow, writes, index, intrinsic, operands)
        Outcome.Foreign(effects, operands) => table!(flow, writes, index, effects, operands, false)
        Outcome.Dispatch(_, operands) => dispatch!(flow, writes, flow.reads, index, operands, callees, !flow.flush && !message, false)
        Outcome.Spawn(_, operands) => spawn!(flow, writes, index, operands, callees)
        Outcome.Contract(effects, operands, breached) => contract!(flow, writes, index, effects, operands, breached)
        Outcome.Open(operands) => open_call!(flow, writes, index, operands)
        Outcome.Unresolved(operands) => (open!(flow, writes, index, operands, CODE_DOUBT); foreign_task_build(flow.ir, index) && split_rng!(writes, index))
        Outcome.Dead() => nothing
    end
    start = started(flow.ir, index, outcome)
    isnothing(start) || access!(flow.reads, value_targets!(flow, something(start)), false, start_effect(flow.ir, index, outcome), EffectKind.iteration)
    flow.record && (flow.call_kinds[index] = call_kinds(outcome, writes, callees, index))
    (message || flow.record) && merge_accesses!(flow.writes, writes, message)
    return nothing
end

"""
Functions whose call starts iteration of first argument (`engine.md`, Facts), by argument count without state:
`iterate(x)`, destructuring `indexed_iterate(x, i)`, `first(x)`, `only(x)` and `isempty(x)`.
"""
const STARTS = IdDict{Any, Int}(iterate => 1, Base.indexed_iterate => 2, first => 1, only => 1, isempty => 1)

"""Contract functions whose call may start iteration: `isempty` docstring says it may consume stateful iterator."""
const MAY_START = (isempty,)

"""Effect of iteration start of call statement `index` with `outcome`: contract of `MAY_START` function gives `possible`."""
function start_effect(ir::CC.IRCode, index::Integer, outcome::Outcome.Type)::Effect
    contract = @match outcome begin
        Outcome.Contract(_, _, _) => true
        _ => false
    end
    callee = constant(ir, (ir.stmts[index][:stmt]::Expr).args[1])
    return contract && something(callee) in MAY_START ? Effect(CODE_DOUBT, index, "") : definite(index)
end

"""
IR value whose iteration call statement `index` of `ir` with `outcome` starts (`STARTS`); `nothing` for other call.
`iterate` without state starts at every resolution: its method continues with state. Other function starts through
Base contract only; static call shows start through callee summary, and own method of type may start nothing.
"""
function started(ir::CC.IRCode, index::Integer, outcome::Outcome.Type)::Union{Nothing, Some{Any}}
    statement = ir.stmts[index][:stmt]::Expr
    statement.head === :call || return nothing
    callee = constant(ir, statement.args[1])
    isnothing(callee) && return nothing
    haskey(STARTS, something(callee)) || return nothing
    length(statement.args) == STARTS[something(callee)] + 1 || return nothing
    contract = @match outcome begin
        Outcome.Contract(_, _, _) => true
        Outcome.Dead() => return nothing
        _ => false
    end
    return contract || something(callee) === iterate ? Some{Any}(statement.args[2]) : nothing
end

"""Add effects of `scratch` to `table`; `only_definite` skips effects with doubt."""
function merge_accesses!(table::OriginAccesses, scratch::OriginAccesses, only_definite::Bool)::Nothing
    for (key, effect) in scratch
        only_definite && level_of(effect.doubt) != Level.none && continue
        table[key] = haskey(table, key) ? stronger(table[key], effect) : effect
    end
    return nothing
end

"""
Kinds of `writes` of call statement `index` with `outcome`, at any certainty, and of holds its callees from `callees`
leave at normal exit: lock gives synchronization, file gives IO.
"""
function call_kinds(outcome::Outcome.Type, writes::OriginAccesses, callees::Callees, index::Integer)::Set{EffectKind.T}
    kinds = Set{EffectKind.T}(kind for (_, _, kind) in keys(writes))
    dispatched = @match outcome begin
        Outcome.Dispatch(_, _) => true
        _ => false
    end
    dispatched || return kinds
    # Held counts keep no exact 0 (`set_hold!`).
    for variant in callees.variants[index], (_, resource) in keys(held_summary(callees.slots, variant).held)
        push!(kinds, resource == Resource.lock ? EffectKind.synchronization : EffectKind.io)
    end
    return kinds
end

"""Call statement summary before span (`CallSummary`): callee, write kinds, may throw, terminates, result used."""
const CallRecord = @NamedTuple{callee::Callee.Type, kinds::Vector{EffectKind.T}, throws::Bool, terminates::Bool, used::Bool}

"""
Facts of call statement `index` of `flow` that records call kinds, whose result code `used`: callee, write kinds, and
compiler `nothrow` and `terminates` flags.
"""
function call_record(flow::Flow, index::Integer, used::Bool)::CallRecord
    kinds = sort!(collect(get(flow.call_kinds, index, Set{EffectKind.T}())))
    terminates = flow.ir.stmts[index][:flag] & CC.IR_FLAG_TERMINATES != 0
    return (callee = outcome_callee(flow.ir.stmts[index][:stmt], something(flow.outcomes[index])), kinds = kinds, throws = may_throw(flow.ir, index), terminates = terminates, used = used)
end

"""Callee of call `statement` with `outcome` (`Callee`): foreign call names C function."""
function outcome_callee(statement::Expr, outcome::Outcome.Type)::Callee.Type
    statement.head === :foreigncall && return Callee.Foreign()
    return @match outcome begin
        Outcome.Builtin(builtin, _) => Callee.Builtin(builtin)
        Outcome.Intrinsic(intrinsic, _) => Callee.Builtin(intrinsic)
        Outcome.Dispatch(instances, _) => methods_callee(Method[instance.def for instance in instances])
        Outcome.Dead() => Callee.Methods(Method[])
        _ => Callee.Open()
    end
end

"""Operands of call `outcome`, callee first where outcome keeps it; none for dead call."""
outcome_operands(outcome::Outcome.Type)::Vector{Operand.Type} = @match outcome begin
    Outcome.Builtin(_, operands) => operands
    Outcome.Intrinsic(_, operands) => operands
    Outcome.Foreign(_, operands) => operands
    Outcome.Dispatch(_, operands) => operands
    Outcome.Spawn(_, operands) => operands
    Outcome.Contract(_, operands, _) => operands
    Outcome.Open(operands) => operands
    Outcome.Unresolved(operands) => operands
    Outcome.Dead() => Operand.Type[]
end

"""
Derive type sources of call `index` with open result type from its `operands` (`engine.md`, Provenance): sources of
each operand with open type. Type value and computed number carry no object, so their sources travel here.
"""
function derive_call!(flow::Flow, index::Integer, operands::AbstractVector{Operand.Type})::Nothing
    Base.isdispatchelem(CC.widenconst(flow.ir.stmts[index][:type])) && return nothing
    derive!(flow, index, reduce(|, (open_sources!(flow, operand) for operand in operands); init = Sources(0)))
    return nothing
end

"""
Transfer call with table `effects` on `arguments` (`engine.md`, Calls, steps 2 and 6): foreign call of C function, or
Base contract. With `typed`, store or copy into argument whose `eltype` points to no object stores nothing: Julia
converts stored value (`Vector{UInt8}`). C arguments are untyped pointers. Access to argument reaches its memory
backing too (`with_backing!`), as callee access does. Writes go into `writes`.
"""
function table!(flow::Flow, writes::OriginAccesses, index::Integer, effects::CallEffects, arguments::AbstractVector{Operand.Type}, typed::Bool)::Nothing
    Base.require_one_based_indexing(arguments)
    targets(position::Integer)::Targets = union_targets(operand_targets!(flow, arguments[at]) for at in role(effects, position, length(arguments)))
    holders(position::Integer)::Targets = union_targets(operand_targets!(flow, arguments[at]) for at in role(effects, position, length(arguments)) if !typed || holds_objects!(flow, operand_type(flow.ir, arguments[at])))
    for position in effects.writes, at in role(effects, position, length(arguments))
        found = operand_targets!(flow, arguments[at])
        alternative_access!(writes, found, with_backing!(flow, found), false, definite(index), effects.write_kind)
    end
    foreach(position -> access!(flow.reads, with_backing!(flow, targets(position)), false, definite(index), EffectKind.memory), effects.reads)
    for (destination, source) in effects.copies
        store!(flow, holders(destination), Step.Element(), load!(flow, targets(source), Step.Element()))
    end
    foreach(((destination, source),) -> store!(flow, holders(destination), Step.Element(), targets(source)), effects.stores)
    # Result that holds no reference (`==`, `length`) skips alias walks.
    points!(flow, flow.ir.stmts[index][:type]) || return nothing
    foreach(position -> assign!(flow, index, targets(position)), effects.result)
    foreach(position -> assign!(flow, index, load!(flow, targets(position), Step.Element())), effects.elements)
    foreach(position -> assign!(flow, index, beneath(flow, targets(position)), CODE_DOUBT), effects.aliases)
    effects.outside && assign!(flow, index, unknown(NO_DOUBT))
    return nothing
end

"""Whether element of collection of `type` can point to object; dead operand (`Union{}`) holds none."""
holds_objects!(flow::Flow, @nospecialize(type::Any))::Bool = type !== Union{} && points!(flow, eltype(type))

"""
Transfer call by Base contract `effects` on `arguments` (`engine.md`, Calls, step 6); `breached` positions hold type
that writes where contract reads: `possible` write. Argument types decide breach, so write takes their dispatch doubt.
Contract holds for methods loaded now, so verdict is closed-world. Writes go into `writes`.
"""
function contract!(flow::Flow, writes::OriginAccesses, index::Integer, effects::CallEffects, arguments::AbstractVector{Operand.Type}, breached::AbstractVector{<:Integer})::Nothing
    Base.require_one_based_indexing(arguments)
    flow.closed_world = true
    table!(flow, writes, index, effects, arguments, true)
    for position in breached
        holders = arguments[role(effects, position, length(arguments))]
        access!(writes, union_targets(operand_targets!(flow, holder) for holder in holders), false, Effect(open_doubt(flow, holders), index, ""), EffectKind.memory)
    end
    return nothing
end

"""
Transfer call at `index` that reaches variants of `callees` (`engine.md`, Calls, steps 3 to 5): one applies its
summary, or leaves callback record for caller when `defers`; more join their summaries and resolve their records here.
Access every member makes keeps most doubt among them; access only some make takes doubt of dispatch between them
(`open_doubt`). Accesses go into `writes` and `reads`. `task`: call runs body of new task (`apply!`).
"""
function dispatch!(flow::Flow, writes::OriginAccesses, reads::OriginAccesses, index::Integer, operands::AbstractVector{Operand.Type}, callees::Callees, defers::Bool, task::Bool)::Nothing
    variants = callees.variants[index]
    if length(variants) == 1
        variant = only(variants)
        apply!(flow, writes, reads, index, summary!(callees, variant), variant, operands, defers, callees, task)
        return nothing
    end
    flow.closed_world = true
    member_writes, member_reads = [OriginAccesses() for _ in variants], [OriginAccesses() for _ in variants]
    for (member, variant) in enumerate(variants)
        apply!(flow, member_writes[member], member_reads[member], index, summary!(callees, variant), variant, operands, false, callees, task)
    end
    partial = open_doubt(flow, operands)
    join_accesses!(writes, member_writes, partial)
    join_accesses!(reads, member_reads, partial)
    return nothing
end

"""
Kinds of task state that body of new task (`Spawn`) keeps to itself (`engine.md`, Task bodies): default RNG state and
task-local storage. New task takes scope of caller, so scoped reads stay.
"""
const TASK_STATE = (EffectKind.default_rng, EffectKind.task_local)

"""Record task build of statement `index` in `writes`: build advances caller RNG to seed new task (`jl_rng_split`)."""
split_rng!(writes::OriginAccesses, index::Integer)::Nothing = (access!(writes, unknown(NO_DOUBT), false, definite(index), EffectKind.default_rng); nothing)

"""Slot of `Task` that holds result of its body: `fetch` loads it."""
const TASK_RESULT = Step.Field(:result)

"""
Transfer call statement `index` that starts new task running body variants of `callees` on `operands`, callable first
(`engine.md`, Task bodies). Body runs as call, so its stores and accesses apply here; writes of task state
(`TASK_STATE`) stay in new task. Body that draws before reseed reads default RNG of caller, since new task derives
its RNG from it; other reads of task state drop. Derivation advances caller RNG (`split_rng!`). Result: new task,
which holds body result (`TASK_RESULT`). Callable holds caller objects, so no callback record waits for caller.
"""
function spawn!(flow::Flow, writes::OriginAccesses, index::Integer, operands::AbstractVector{Operand.Type}, callees::Callees)::Nothing
    body_writes, body_reads = OriginAccesses(), OriginAccesses()
    dispatch!(flow, body_writes, body_reads, index, operands, callees, false, true)
    draws = any(variant -> summary!(callees, variant).rng.draws, callees.variants[index])
    merge_accesses!(writes, filter(((key, _),) -> !(last(key) in TASK_STATE), body_writes), false)
    merge_accesses!(flow.reads, filter(((key, _),) -> !(last(key) in TASK_STATE) || (draws && last(key) == EffectKind.default_rng), body_reads), false)
    split_rng!(writes, index)
    assign!(flow, index, Targets(Origin.Allocation(index) => NO_DOUBT))
    return nothing
end

"""
Record in `table` join of accesses of each member in `members`: most doubt among members, cause of first member with
most doubtful level. Access absent from some member is at least `partial`: operand types decide which member runs.
Blind access counts as absent beside exact one: blind spot of one member leaves write of other `possible`.
"""
function join_accesses!(table::OriginAccesses, members::AbstractVector{OriginAccesses}, partial::Doubt)::Nothing
    for key in union(keys.(members)...)
        present = [member[key] for member in members if haskey(member, key)]
        exact = [effect for effect in present if level_of(effect.doubt) != Level.blind]
        found = isempty(exact) ? present : exact
        first_worst = reduce((first, second) -> level_of(second.doubt) > level_of(first.doubt) ? second : first, found)
        doubt = reduce(most, (effect.doubt for effect in found))
        length(found) == length(members) || (doubt = most(doubt, partial))
        effect = Effect(doubt, first_worst.cause, first_worst.reason)
        table[key] = haskey(table, key) ? stronger(table[key], effect) : effect
    end
    return nothing
end

"""Transfer builtin call (`engine.md`, Calls, step 1); writes go into `writes`."""
function builtin!(flow::Flow, writes::OriginAccesses, index::Integer, @nospecialize(builtin::Any), operands::AbstractVector{Operand.Type})::Nothing
    Base.require_one_based_indexing(operands)
    targets(position::Integer)::Targets = operand_targets!(flow, operands[position])
    if builtin === Core.getfield
        binding = module_global(flow, operands)
        if isnothing(binding)
            # Own name: closure of field write branch captures `field`; second assignment boxes it.
            read_field = operand_constant(flow.ir, operands[2])
            kind = field_kind(operand_type(flow.ir, operands[1]), read_field, flow.scheduler)
            access!(flow.reads, targets(1), false, definite(index), kind)
            draw!(flow, index, kind)
            assign!(flow, index, load_field!(flow, operands[1], read_field))
        else
            read_global!(flow, index, something(binding))
        end
    elseif haskey(FIELD_WRITES, builtin)
        field = operand_constant(flow.ir, operands[2])
        slot = slot_type(operand_type(flow.ir, operands[1]), field)
        kind = field_kind(operand_type(flow.ir, operands[1]), field, flow.scheduler)
        write!(flow, writes, index, FIELD_WRITES[builtin], operands, targets(1), load_field!(flow, operands[1], field), values -> store_field!(flow, operands[1], field, values), slot, kind)
    elseif builtin === Core.getglobal
        binding = module_global(flow, operands)
        if isnothing(binding)
            assign!(flow, index, unknown(CODE_DOUBT))
        else
            read_global!(flow, index, something(binding))
        end
    elseif haskey(GLOBAL_WRITES, builtin)
        global_write!(flow, writes, index, GLOBAL_WRITES[builtin], operands)
    elseif haskey(ELEMENT_WRITES, builtin)
        element_write!(flow, writes, index, ELEMENT_WRITES[builtin], operands)
    elseif builtin === Core.memoryrefget
        access!(flow.reads, targets(1), false, definite(index), EffectKind.memory)
        assign!(flow, index, load!(flow, targets(1), Step.Element()))
    elseif builtin === Core.memoryref_isassigned
        access!(flow.reads, targets(1), false, definite(index), EffectKind.memory)
    elseif builtin === Core.memorynew
        allocate!(flow, index)
    elseif builtin === Core.tuple || builtin === Core.svec
        allocate!(flow, index)
        # `Rest` elements have unknown positions: unknown slot.
        for position in eachindex(operands)
            store!(flow, flow.values[index], is_rest(operands[position]) ? nothing : Step.Position(position), targets(position))
        end
    elseif builtin === Core._expr
        allocate!(flow, index)
        store!(flow, flow.values[index], nothing, union_targets(targets(position) for position in eachindex(operands)))
    elseif builtin === Core.memoryrefnew || builtin === Core.typeassert
        assign!(flow, index, targets(1))
    elseif builtin === Core.compilerbarrier
        assign!(flow, index, targets(2))
    elseif builtin === Core.ifelse
        assign!(flow, index, union_targets((targets(2), targets(3))))
    elseif builtin === Core._svec_ref
        assign!(flow, index, load_any(flow, targets(1)))
    elseif builtin === Core.current_scope
        access!(flow.reads, unknown(NO_DOUBT), false, definite(index), EffectKind.scoped_read)
        assign!(flow, index, unknown(CODE_DOUBT))
    elseif !(builtin in INERT_BUILTINS)
        # Definition builtins (`_structtype`, `declare_global`) change global state; outside call resolution they stay open.
        open!(flow, writes, index, operands, CODE_DOUBT)
    end
    return nothing
end

"""Place of global `binding` as targets: write to binding writes it."""
global_place(binding::GlobalRef)::Targets = Targets(Origin.Caller(Place.At(Root.Global(binding), NO_STEPS)) => NO_DOUBT)

"""Read of global `binding` at statement `index`: mutable binding counts as read."""
function read_global!(flow::Flow, index::Integer, binding::GlobalRef)::Nothing
    isconst(binding) || access!(flow.reads, global_place(binding), false, definite(index), EffectKind.memory)
    assign!(flow, index, global_targets(flow, binding))
    return nothing
end

"""Global binding that call with constant module and symbol operands names; `nothing` otherwise."""
function module_global(flow::Flow, operands::AbstractVector{Operand.Type})::Union{Nothing, Some{GlobalRef}}
    Base.require_one_based_indexing(operands)
    length(operands) >= 2 || return nothing
    owner, name = operand_constant(flow.ir, operands[1]), operand_constant(flow.ir, operands[2])
    (isnothing(owner) || isnothing(name)) && return nothing
    something(owner) isa Module && something(name) isa Symbol || return nothing
    return Some(GlobalRef(something(owner), something(name)))
end

"""
Transfer write of slot of `objects` with `shape` and call `operands`: record write, store value, and set result.
`old` holds slot content before write; `store` puts targets into slot of declared type `slot`. Slot of type that
points to no object holds no targets. `modify` operator call stays open. Writes of `kind` go into `writes`.
"""
function write!(flow::Flow, writes::OriginAccesses, index::Integer, shape::Shape, operands::AbstractVector{Operand.Type}, objects::Targets, old::Targets, store::Function, @nospecialize(slot::Any), kind::EffectKind.T)::Nothing
    Base.require_one_based_indexing(operands)
    alternative_access!(writes, objects, objects, false, definite(index), kind)
    shape.returns in (Returns.stored, Returns.object) || (access!(flow.reads, objects, false, definite(index), kind); draw!(flow, index, kind))
    holds = points!(flow, slot)
    old = holds ? old : Targets()
    given = holds ? operand_targets!(flow, operands[shape.stored]) : Targets()
    stored = if shape.operator == 0
        given
    else
        reached = union_targets((operand_targets!(flow, operands[shape.operator]), old, given))
        open_effects!(flow, writes, index, reached, CODE_DOUBT)
        union_targets((raised(reached, CODE_DOUBT), unknown(CODE_DOUBT)))
    end
    store(stored)
    @match shape.returns begin
        Returns.stored => assign!(flow, index, given)
        Returns.object => assign!(flow, index, objects)
        Returns.old => assign!(flow, index, old)
        Returns.pair => pack!(flow, index, Step.Field(:first) => old, Step.Field(:second) => stored)
        Returns.replaced => pack!(flow, index, Step.Field(:old) => old)
        Returns.flag => nothing
    end
    return nothing
end

"""
Transfer write of global binding `operands` name, into `writes`; binding that is not constant writes unknown object.
"""
function global_write!(flow::Flow, writes::OriginAccesses, index::Integer, shape::Shape, operands::AbstractVector{Operand.Type})::Nothing
    found = module_global(flow, operands)
    if isnothing(found)
        write!(flow, writes, index, shape, operands, unknown(CODE_DOUBT), unknown(CODE_DOUBT), values -> store!(flow, unknown(CODE_DOUBT), nothing, values), Any, EffectKind.memory)
        return nothing
    end
    binding = something(found)
    slot = Core.get_binding_type(binding.mod, binding.name)
    write!(flow, writes, index, shape, operands, global_place(binding), global_targets(flow, binding), values -> bind!(flow, binding, values), slot, EffectKind.memory)
    return nothing
end

"""Result of statement `index` is fresh immutable object holding `fields` (`Pair`, named tuple)."""
function pack!(flow::Flow, index::Integer, fields::Pair{<:Step.Type, Targets}...)::Nothing
    allocate!(flow, index)
    foreach(((step, targets),) -> store!(flow, flow.values[index], step, targets), fields)
    return nothing
end

"""Transfer write of memory element or pointer target, into `writes`: first operand holds memory or pointer."""
function element_write!(flow::Flow, writes::OriginAccesses, index::Integer, shape::Shape, operands::AbstractVector{Operand.Type})::Nothing
    Base.require_one_based_indexing(operands)
    objects = operand_targets!(flow, operands[1])
    slot = element_type(operand_type(flow.ir, operands[1]))
    write!(flow, writes, index, shape, operands, objects, load!(flow, objects, Step.Element()), values -> store!(flow, objects, Step.Element(), values), slot, EffectKind.memory)
    return nothing
end

"""Declared type of constant `field` (`Some`; `nothing` when not constant) of object of `type`; `Any` when unknown."""
function slot_type(@nospecialize(type::Any), field::Union{Nothing, Some{Any}})::Any
    isnothing(field) && return Any
    name, fields = something(field), layout(type)
    isnothing(fields) && return Any
    known = name isa Symbol ? hasfield(fields, name) : name isa Int && 1 <= name <= fieldcount(fields)
    # Field type of family body names its variables; rewrap keeps them bound.
    return known ? Base.rewrap_unionall(fieldtype(fields, name), type) : Any
end

"""Element type of memory reference or pointer `type`; `Any` when unknown."""
function element_type(@nospecialize(type::Any))::Any
    type isa DataType || return Any
    type <: GenericMemoryRef && return type.parameters[2]
    type <: Ptr && return type.parameters[1]
    return Any
end

"""
Targets of loading constant `field` (`Some` of it; `nothing` when not constant) from `object`. Memory backing field
adds no step; `MemoryRef` stands for its memory, so its `mem` field gives same targets. Data pointer of memory (`ptr`)
stands for memory too: write through it writes memory, as write to `Vector` elements writes `Vector`.
"""
function load_field!(flow::Flow, object::Operand.Type, field::Union{Nothing, Some{Any}})::Targets
    objects = operand_targets!(flow, object)
    isnothing(field) && return load_any(flow, objects)
    type, name = operand_type(flow.ir, object), something(field)
    (type <: GenericMemoryRef || (type <: GenericMemory && name === :ptr)) && return objects
    step = field_step(type, name)
    isnothing(step) && return load_any(flow, objects)
    backing_field(type, name) || return load!(flow, objects, something(step))
    found = Targets()
    for (origin, doubt) in objects
        fresh_origin(origin) || add!(found, origin, doubt)
        foreach(((memory, flag),) -> add!(found, memory, most(flag, doubt)), get(flow.backing, origin, Targets()))
    end
    return found
end

"""Store `values` into constant `field` of `object` (`Some`; `nothing` when not constant: unknown slot)."""
function store_field!(flow::Flow, object::Operand.Type, field::Union{Nothing, Some{Any}}, values::Targets)::Nothing
    objects = operand_targets!(flow, object)
    step = isnothing(field) ? nothing : field_step(operand_type(flow.ir, object), something(field))
    if !isnothing(step) && backing_field(operand_type(flow.ir, object), something(field))
        store_backing!(flow, objects, values)
    else
        store!(flow, objects, step, values)
    end
    return nothing
end

"""
Transfer intrinsic call: pointer writes into `writes`, and reads; other intrinsics pass pointer operands to result.
"""
function intrinsic!(flow::Flow, writes::OriginAccesses, index::Integer, @nospecialize(intrinsic::Any), operands::AbstractVector{Operand.Type})::Nothing
    Base.require_one_based_indexing(operands)
    intrinsics = Core.Intrinsics
    if haskey(ELEMENT_WRITES, intrinsic)
        element_write!(flow, writes, index, ELEMENT_WRITES[intrinsic], operands)
    elseif intrinsic === intrinsics.pointerref || intrinsic === intrinsics.atomic_pointerref
        pointers = operand_targets!(flow, operands[1])
        access!(flow.reads, pointers, false, definite(index), EffectKind.memory)
        assign!(flow, index, load!(flow, pointers, Step.Element()))
    elseif intrinsic === intrinsics.llvmcall
        open!(flow, writes, index, operands, CODE_DOUBT)
    elseif intrinsic === intrinsics.cglobal
        assign!(flow, index, unknown(CODE_DOUBT))
    else
        # Pointer arithmetic and `bitcast` keep pointer into same object.
        assign!(flow, index, union_targets(operand_targets!(flow, operand) for operand in operands))
    end
    return nothing
end

"""
Write into `writes` and read with `doubt` below every origin of `objects` that open call at statement `index` reaches.
"""
function open_effects!(flow::Flow, writes::OriginAccesses, index::Integer, objects::Targets, doubt::Doubt)::Nothing
    effect, reached = Effect(doubt, index, ""), beneath(flow, objects)
    access!(writes, reached, true, effect, EffectKind.memory)
    access!(flow.reads, reached, true, effect, EffectKind.memory)
    return nothing
end

"""
Whether value of `type` is `TaskLocalRNG`, or holds one in field at most `depth` levels down: tuple that unresolved
splat passes, closure or struct over RNG.
"""
function holds_task_rng_type(@nospecialize(type::Any), depth::Integer)::Bool
    type isa DataType || return false
    type <: Random.TaskLocalRNG && return true
    (depth > 0 && isconcretetype(type)) || return false
    return any(field -> holds_task_rng_type(field, depth - 1), fieldtypes(type))
end

"""
Transfer open call (`engine.md`, Calls, step 7) with `code` `doubt`: write into `writes` and read below every operand;
result may point into operands, one direction, and to unknown object. `TaskLocalRNG` holds no object, so operand that
is or holds one (`holds_task_rng_type`) lets call draw from default RNG of current task.
"""
function open!(flow::Flow, writes::OriginAccesses, index::Integer, operands::AbstractVector{Operand.Type}, doubt::Doubt)::Nothing
    objects = union_targets(operand_targets!(flow, operand) for operand in operands)
    open_effects!(flow, writes, index, objects, doubt)
    if any(operand -> holds_task_rng_type(operand_type(flow.ir, operand), 3), operands)
        access!(writes, unknown(NO_DOUBT), false, Effect(doubt, index, ""), EffectKind.default_rng)
        access!(flow.reads, unknown(NO_DOUBT), false, Effect(doubt, index, ""), EffectKind.default_rng)
        draw!(flow, index, EffectKind.default_rng)
    end
    assign!(flow, index, union_targets((objects, unknown(doubt))), doubt)
    return nothing
end

"""
Transfer open call statement `index` with `operands` (callee first) into `writes`: effects whose open types decide
doubt. Whatever method runs, IO function (`IO_FUNCTIONS`) writes each `IO` stream operand (`stream_positions`), and
random function (`RNG_DRAWS`) draws from its `AbstractRNG` first argument. `TaskLocalRNG` holds no state: draw from it
changes default RNG state of current task, on `unknown`.
"""
function open_call!(flow::Flow, writes::OriginAccesses, index::Integer, operands::AbstractVector{Operand.Type})::Nothing
    Base.require_one_based_indexing(operands)
    open!(flow, writes, index, operands, open_doubt(flow, operands))
    callee = operand_constant(flow.ir, operands[1])
    isnothing(callee) && return nothing
    if something(callee) in IO_FUNCTIONS
        arguments = @view(operands[2:end])
        for position in stream_positions(something(callee), length(arguments))
            operand = arguments[position]
            special_kind(operand_type(flow.ir, operand)) == EffectKind.io || continue
            streams = operand_targets!(flow, operand)
            alternative_access!(writes, streams, streams, true, definite(index), EffectKind.io)
        end
    end
    (length(operands) >= 2 && operand_type(flow.ir, operands[2]) <: AbstractRNG && something(callee) in RNG_DRAWS) || return nothing
    task_rng = operand_type(flow.ir, operands[2]) <: Random.TaskLocalRNG
    rng, kind = task_rng ? (unknown(NO_DOUBT), EffectKind.default_rng) : (operand_targets!(flow, operands[2]), EffectKind.rng_argument)
    access!(writes, rng, false, definite(index), kind)
    access!(flow.reads, rng, false, definite(index), kind)
    draw!(flow, index, kind)
    return nothing
end

"""
Doubt of open dispatch with `operands` (`engine.md`, Provenance): sources of each operand whose type leaves dispatch
open. Call open without open operand type: doubt in code.
"""
function open_doubt(flow::Flow, operands::AbstractVector{Operand.Type})::Doubt
    sources = reduce(|, (open_sources!(flow, operand) for operand in operands); init = Sources(0))
    return Doubt(Level.code, sources == 0 ? INHERENT : sources)
end

"""
Type sources of `operand` when its type leaves dispatch open, else none. `FunctionStandIn` stands for any function
Corset chose.
"""
function open_sources!(flow::Flow, operand::Operand.Type)::Sources
    type = operand_type(flow.ir, operand)
    type === FunctionStandIn && return OPAQUE
    Base.isdispatchelem(type) && return Sources(0)
    return type_sources(flow, operand_targets!(flow, operand), derived_of(flow, operand))
end

"""
Sources of open type of value with `targets`: parameter of each caller place, sources of each `code` chain, and
`INHERENT` for global or fresh object merge. Fresh object has concrete type: its contents decide. Value whose objects
give no source takes its `derived` sources: type value and computed number hold no object.
"""
function type_sources(flow::Flow, targets::Targets, derived::Sources)::Sources
    count(fresh_origin, keys(targets)) > 1 && return INHERENT
    sources = Sources(0)
    for (origin, doubt) in beneath(flow, targets)
        sources |= sources_of(doubt)
        sources |= origin_source(origin)
    end
    sources == 0 && (sources = derived)
    return sources == 0 ? INHERENT : sources
end

"""Source of open type at `origin`: parameter of caller place, `INHERENT` for global; none for fresh and unknown objects."""
function origin_source(origin::Origin.Type)::Sources
    root = @match origin begin
        Origin.Caller(place) => root_of(place)
        _ => return Sources(0)
    end
    return @match root begin
        Root.Parameter(position) => parameter_source(position)
        _ => INHERENT
    end
end

"""
Targets of callee place `place` from argument targets `arguments` (`engine.md`, Calls, step 3). Global places map to
same global; `Elsewhere` to objects outside caller places (`outside_targets!`); `Deep` to every object below root, blind.
"""
function map_place!(flow::Flow, place::Place.Type, arguments::AbstractVector{Targets})::Targets
    Base.require_one_based_indexing(arguments)
    return @match place begin
        Place.At(Root.Parameter(position), steps) => foldl((objects, step) -> load!(flow, objects, step), steps; init = arguments[position])
        Place.At(Root.Global(binding), steps) => foldl((objects, step) -> load!(flow, objects, step), steps; init = global_targets(flow, binding))
        Place.Deep(Root.Parameter(position)) => deep(flow, arguments[position])
        Place.Deep(Root.Global(binding)) => deep(flow, global_targets(flow, binding))
        _ => outside_targets!(flow)
    end
end

"""
Every origin `objects` reach through any slot; caller objects collapse to `Deep` of their root (`engine.md`, Calls).
Origins of `objects` keep their doubt: write below callee `Deep` place changes them. Origins in their slots are blind:
callee may leave them unchanged.
"""
function deep(flow::Flow, objects::Targets)::Targets
    found, seen, pending = Targets(), Set{Origin.Type}(keys(objects)), collect(keys(objects))
    foreach(((origin, doubt),) -> add!(found, collapsed(origin), doubt), objects)
    while !isempty(pending)
        foreach_content(flow, pop!(pending)) do targets
            for target in keys(targets)
                target in seen && continue
                push!(seen, target)
                add!(found, collapsed(target), BLIND_DOUBT)
                push!(pending, target)
            end
        end
    end
    return found
end

"""Caller object `origin` collapsed to `Deep` of its root; other origin, `Deep` one included, stays."""
collapsed(origin::Origin.Type)::Origin.Type = @match origin begin
    Origin.Caller(Place.At(root, _)) => Origin.Caller(Place.Deep(root))
    _ => origin
end

"""
Targets of callee object outside its caller places: unknown object, and each object stored into it, directly or below.
Each keeps doubt of its chain, at least `code`: callee may load any of them. Walk revisits object whose doubt changes, as
`beneath` does; it charges each link it follows to `flow.work` and stops past limit. Caller object keeps own origin, so
later loads see callee stores into it, and adds `Deep` of its root (`collapsed`): callee may reach below it.
"""
function outside_targets!(flow::Flow)::Targets
    reached, pending = unknown(NO_DOUBT), [Origin.Unknown()]
    while !isempty(pending) && !over_budget(flow)
        origin = pop!(pending)
        foreach_content(flow, origin) do targets
            flow.work += length(targets)
            for (target, doubt) in targets
                add!(reached, target, most(most(doubt, CODE_DOUBT), reached[origin])) && push!(pending, target)
            end
        end
    end
    found = copy(reached)
    for (origin, doubt) in reached
        add!(found, collapsed(origin), doubt)
    end
    return found
end
