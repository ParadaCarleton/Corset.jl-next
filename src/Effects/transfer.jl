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
previous round at `index` give way to this round.
"""
function call!(flow::Flow, index::Int, outcome::Outcome.Type, callees::Callees)::Nothing
    delete!(flow.callbacks, index)
    @match outcome begin
        Outcome.Builtin(builtin, operands) => builtin!(flow, index, builtin, operands)
        Outcome.Intrinsic(intrinsic, operands) => intrinsic!(flow, index, intrinsic, operands)
        Outcome.Foreign(effects, operands) => table!(flow, index, effects, operands)
        Outcome.Dispatch(_, operands) => dispatch!(flow, index, operands, callees)
        Outcome.Contract(effects, operands, breached) => contract!(flow, index, effects, operands, breached)
        Outcome.Open(operands) => open!(flow, index, operands, open_doubt(flow, operands))
        Outcome.Unresolved(operands) => open!(flow, index, operands, CODE_DOUBT)
        Outcome.Dead() => nothing
    end
    return nothing
end

"""
Transfer call with table `effects` on `arguments` (`effects.md`, Calls, steps 2 and 6): foreign call of C function, or
Base contract.
"""
function table!(flow::Flow, index::Int, effects::CallEffects, arguments::Vector{Operand.Type})::Nothing
    targets(position::Int)::Targets = union_targets(operand_targets(flow, arguments[at]) for at in role(effects, position, length(arguments)))
    foreach(position -> access!(flow.writes, targets(position), false, definite(index)), effects.writes)
    foreach(position -> access!(flow.reads, targets(position), false, definite(index)), effects.reads)
    for (destination, source) in effects.copies
        store!(flow, targets(destination), Step.Element(), load(flow, targets(source), Step.Element()))
    end
    foreach(((destination, source),) -> store!(flow, targets(destination), Step.Element(), targets(source)), effects.stores)
    # Result that holds no reference (`==`, `length`) skips alias walks.
    points(flow, flow.ir.stmts[index][:type]) || return nothing
    foreach(position -> assign!(flow, index, targets(position)), effects.result)
    foreach(position -> assign!(flow, index, load(flow, targets(position), Step.Element())), effects.elements)
    foreach(position -> assign!(flow, index, beneath(flow, targets(position)), CODE_DOUBT), effects.aliases)
    return nothing
end

"""
Transfer call by Base contract `effects` on `arguments` (`effects.md`, Calls, step 6); `breached` positions hold type
that writes where contract reads: `possible` write. Contract holds for methods loaded now, so verdict is closed-world.
"""
function contract!(flow::Flow, index::Int, effects::CallEffects, arguments::Vector{Operand.Type}, breached::Vector{Int})::Nothing
    flow.closed_world = true
    table!(flow, index, effects, arguments)
    for position in breached
        objects = union_targets(operand_targets(flow, arguments[at]) for at in role(effects, position, length(arguments)))
        access!(flow.writes, objects, false, Effect(CODE_DOUBT, index, ""))
    end
    return nothing
end

"""
Transfer call at `index` that reaches variants of `callees` (`effects.md`, Calls, steps 3 to 5): one applies its
summary, or leaves callback record for caller; more join their summaries and resolve their records here. Access every
member makes keeps most doubt among them; access only some make is at least `possible`.
"""
function dispatch!(flow::Flow, index::Int, operands::Vector{Operand.Type}, callees::Callees)::Nothing
    variants = callees.variants[index]
    if length(variants) == 1
        variant = only(variants)
        apply!(flow, flow.writes, flow.reads, index, summary!(callees, variant), variant, operands, !flow.flush, callees)
        return nothing
    end
    flow.closed_world = true
    writes, reads = [OriginAccesses() for _ in variants], [OriginAccesses() for _ in variants]
    for (member, variant) in enumerate(variants)
        apply!(flow, writes[member], reads[member], index, summary!(callees, variant), variant, operands, false, callees)
    end
    join_accesses!(flow.writes, writes)
    join_accesses!(flow.reads, reads)
    return nothing
end

"""
Record in `table` join of accesses of each member in `members`: most doubt among members, cause of first member with
most doubtful level. Access absent from some member is at least `code`, doubt in code itself.
"""
function join_accesses!(table::OriginAccesses, members::Vector{OriginAccesses})::Nothing
    for key in union(keys.(members)...)
        found = [member[key] for member in members if haskey(member, key)]
        first_worst = reduce((first, second) -> level_of(second.doubt) > level_of(first.doubt) ? second : first, found)
        doubt = reduce(most, (effect.doubt for effect in found))
        length(found) == length(members) || (doubt = most(doubt, CODE_DOUBT))
        effect = Effect(doubt, first_worst.cause, first_worst.reason)
        table[key] = haskey(table, key) ? stronger(table[key], effect) : effect
    end
    return nothing
end

"""Constant value of call `operand`; `nothing` when not constant."""
function operand_constant(flow::Flow, operand::Operand.Type)::Union{Nothing, Some{Any}}
    return @match operand begin
        Operand.Value(value) => constant(flow.ir, value)
        _ => nothing
    end
end

"""Transfer builtin call (`effects.md`, Calls, step 1)."""
function builtin!(flow::Flow, index::Int, builtin::Any, operands::Vector{Operand.Type})::Nothing
    targets(position::Int)::Targets = operand_targets(flow, operands[position])
    if builtin === Core.getfield
        binding = module_global(flow, operands)
        if isnothing(binding)
            access!(flow.reads, targets(1), false, definite(index))
            assign!(flow, index, load_field(flow, operands[1], operand_constant(flow, operands[2])))
        else
            read_global!(flow, index, something(binding))
        end
    elseif haskey(FIELD_WRITES, builtin)
        field = operand_constant(flow, operands[2])
        slot = slot_type(operand_type(flow.ir, operands[1]), field)
        write!(flow, index, FIELD_WRITES[builtin], operands, targets(1), load_field(flow, operands[1], field), values -> store_field!(flow, operands[1], field, values), slot)
    elseif builtin === Core.getglobal
        binding = module_global(flow, operands)
        isnothing(binding) ? assign!(flow, index, unknown(CODE_DOUBT)) : read_global!(flow, index, something(binding))
    elseif haskey(GLOBAL_WRITES, builtin)
        global_write!(flow, index, GLOBAL_WRITES[builtin], operands)
    elseif haskey(ELEMENT_WRITES, builtin)
        element_write!(flow, index, ELEMENT_WRITES[builtin], operands)
    elseif builtin === Core.memoryrefget
        access!(flow.reads, targets(1), false, definite(index))
        assign!(flow, index, load(flow, targets(1), Step.Element()))
    elseif builtin === Core.memoryref_isassigned
        access!(flow.reads, targets(1), false, definite(index))
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
        assign!(flow, index, unknown(CODE_DOUBT))
    elseif !(builtin in INERT_BUILTINS)
        # Definition builtins (`_structtype`, `declare_global`) change global state; outside call resolution they stay open.
        open!(flow, index, operands, CODE_DOUBT)
    end
    return nothing
end

"""Place of global `binding` as targets: write to binding writes it."""
global_place(binding::GlobalRef)::Targets = Targets(Origin.Caller(Place.At(Root.Global(binding), Step.Type[])) => NO_DOUBT)

"""Read of global `binding` at statement `index`: mutable binding counts as read."""
function read_global!(flow::Flow, index::Int, binding::GlobalRef)::Nothing
    isconst(binding) || access!(flow.reads, global_place(binding), false, definite(index))
    assign!(flow, index, global_targets(flow, binding))
    return nothing
end

"""Global binding that call with constant module and symbol operands names; `nothing` otherwise."""
function module_global(flow::Flow, operands::Vector{Operand.Type})::Union{Nothing, Some{GlobalRef}}
    length(operands) >= 2 || return nothing
    owner, name = operand_constant(flow, operands[1]), operand_constant(flow, operands[2])
    (isnothing(owner) || isnothing(name)) && return nothing
    something(owner) isa Module && something(name) isa Symbol || return nothing
    return Some(GlobalRef(something(owner), something(name)))
end

"""
Transfer write of slot of `objects` with `shape` and call `operands`: record write, store value, and set result.
`old` holds slot content before write; `store` puts targets into slot of declared type `slot`. Slot of type that
points to no object holds no targets. `modify` operator call stays open.
"""
function write!(flow::Flow, index::Int, shape::Shape, operands::Vector{Operand.Type}, objects::Targets, old::Targets, store::Function, slot::Any)::Nothing
    access!(flow.writes, objects, false, definite(index))
    shape.returns in (Returns.stored, Returns.object) || access!(flow.reads, objects, false, definite(index))
    holds = points(flow, slot)
    old = holds ? old : Targets()
    given = holds ? operand_targets(flow, operands[shape.stored]) : Targets()
    stored = if shape.operator == 0
        given
    else
        reached = union_targets((operand_targets(flow, operands[shape.operator]), old, given))
        open_effects!(flow, index, reached, CODE_DOUBT)
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

"""Transfer write of global binding `operands` name; binding that is not constant writes unknown object."""
function global_write!(flow::Flow, index::Int, shape::Shape, operands::Vector{Operand.Type})::Nothing
    found = module_global(flow, operands)
    if isnothing(found)
        write!(flow, index, shape, operands, unknown(CODE_DOUBT), unknown(CODE_DOUBT), values -> store!(flow, unknown(CODE_DOUBT), nothing, values), Any)
        return nothing
    end
    binding = something(found)
    slot = Core.get_binding_type(binding.mod, binding.name)
    write!(flow, index, shape, operands, global_place(binding), global_targets(flow, binding), values -> bind!(flow, binding, values), slot)
    return nothing
end

"""Result of statement `index` is fresh immutable object holding `fields` (`Pair`, named tuple)."""
function pack!(flow::Flow, index::Int, fields::Pair{<:Step.Type, Targets}...)::Nothing
    allocate!(flow, index)
    foreach(((step, targets),) -> store!(flow, flow.values[index], step, targets), fields)
    return nothing
end

"""Transfer write of memory element or pointer target: first operand holds memory or pointer."""
function element_write!(flow::Flow, index::Int, shape::Shape, operands::Vector{Operand.Type})::Nothing
    objects = operand_targets(flow, operands[1])
    slot = element_type(operand_type(flow.ir, operands[1]))
    write!(flow, index, shape, operands, objects, load(flow, objects, Step.Element()), values -> store!(flow, objects, Step.Element(), values), slot)
    return nothing
end

"""Declared type of constant `field` (`Some`; `nothing` when not constant) of object of `type`; `Any` when unknown."""
function slot_type(type::Any, field::Union{Nothing, Some{Any}})::Any
    isnothing(field) && return Any
    name = something(field)
    type isa DataType || return Any
    isconcretetype(type) || return Any
    known = name isa Symbol ? hasfield(type, name) : name isa Int && 1 <= name <= fieldcount(type)
    return known ? fieldtype(type, name) : Any
end

"""Element type of memory reference or pointer `type`; `Any` when unknown."""
function element_type(type::Any)::Any
    type isa DataType || return Any
    type <: GenericMemoryRef && return type.parameters[2]
    type <: Ptr && return type.parameters[1]
    return Any
end

"""
Targets of loading constant `field` (`Some` of it; `nothing` when not constant) from `object`. Memory backing field
adds no step; `MemoryRef` stands for its memory, so its `mem` field gives same targets.
"""
function load_field(flow::Flow, object::Operand.Type, field::Union{Nothing, Some{Any}})::Targets
    objects = operand_targets(flow, object)
    isnothing(field) && return load_any(flow, objects)
    type, name = operand_type(flow.ir, object), something(field)
    type <: GenericMemoryRef && return objects
    step = field_step(type, name)
    isnothing(step) && return load_any(flow, objects)
    backing_field(type, name) || return load(flow, objects, something(step))
    found = Targets()
    for (origin, doubt) in objects
        fresh_origin(origin) || add!(found, origin, doubt)
        foreach(((memory, flag),) -> add!(found, memory, most(flag, doubt)), get(flow.backing, origin, Targets()))
    end
    return found
end

"""Store `values` into constant `field` of `object` (`Some`; `nothing` when not constant: unknown slot)."""
function store_field!(flow::Flow, object::Operand.Type, field::Union{Nothing, Some{Any}}, values::Targets)::Nothing
    objects = operand_targets(flow, object)
    step = isnothing(field) ? nothing : field_step(operand_type(flow.ir, object), something(field))
    if !isnothing(step) && backing_field(operand_type(flow.ir, object), something(field))
        store_backing!(flow, objects, values)
    else
        store!(flow, objects, step, values)
    end
    return nothing
end

"""Transfer intrinsic call: pointer writes and reads; other intrinsics pass pointer operands to result."""
function intrinsic!(flow::Flow, index::Int, intrinsic::Any, operands::Vector{Operand.Type})::Nothing
    intrinsics = Core.Intrinsics
    if haskey(ELEMENT_WRITES, intrinsic)
        element_write!(flow, index, ELEMENT_WRITES[intrinsic], operands)
    elseif intrinsic === intrinsics.pointerref || intrinsic === intrinsics.atomic_pointerref
        pointers = operand_targets(flow, operands[1])
        access!(flow.reads, pointers, false, definite(index))
        assign!(flow, index, load(flow, pointers, Step.Element()))
    elseif intrinsic === intrinsics.llvmcall
        open!(flow, index, operands, CODE_DOUBT)
    elseif intrinsic === intrinsics.cglobal
        assign!(flow, index, unknown(CODE_DOUBT))
    else
        # Pointer arithmetic and `bitcast` keep pointer into same object.
        assign!(flow, index, union_targets(operand_targets(flow, operand) for operand in operands))
    end
    return nothing
end

"""Write and read with `doubt` below every origin of `objects` that open call at statement `index` reaches."""
function open_effects!(flow::Flow, index::Int, objects::Targets, doubt::Doubt)::Nothing
    effect, reached = Effect(doubt, index, ""), beneath(flow, objects)
    access!(flow.writes, reached, true, effect)
    access!(flow.reads, reached, true, effect)
    return nothing
end

"""
Transfer open call (`effects.md`, Calls, step 7) with `code` `doubt`: write and read below every operand; result may
point into operands, one direction, and to unknown object.
"""
function open!(flow::Flow, index::Int, operands::Vector{Operand.Type}, doubt::Doubt)::Nothing
    objects = union_targets(operand_targets(flow, operand) for operand in operands)
    open_effects!(flow, index, objects, doubt)
    assign!(flow, index, union_targets((objects, unknown(doubt))), doubt)
    return nothing
end

"""
Doubt of open dispatch with `operands` (`effects.md`, Provenance): sources of each operand whose type leaves dispatch
open. `FunctionStandIn` stands for any function Corset chose. Call open without open operand type: doubt in code.
"""
function open_doubt(flow::Flow, operands::Vector{Operand.Type})::Doubt
    sources = Sources(0)
    for operand in operands
        type = operand_type(flow.ir, operand)
        if type === FunctionStandIn
            sources |= OPAQUE
        elseif !Base.isdispatchelem(type)
            sources |= type_sources(flow, operand_targets(flow, operand))
        end
    end
    return Doubt(Level.code, sources == 0 ? INHERENT : sources)
end

"""
Sources of open type of value with `targets`: parameter of each caller place, sources of each `code` chain, and
`INHERENT` for global or fresh object merge. Fresh object has concrete type: its contents decide.
"""
function type_sources(flow::Flow, targets::Targets)::Sources
    count(fresh_origin, keys(targets)) > 1 && return INHERENT
    sources = Sources(0)
    for (origin, doubt) in beneath(flow, targets)
        sources |= sources_of(doubt)
        sources |= origin_source(origin)
    end
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
Targets of callee place `place` from argument targets `arguments` (`effects.md`, Calls, step 3). Global places map to
same global; `Elsewhere` to unknown object; `Deep` to every object below root, blind.
"""
function map_place(flow::Flow, place::Place.Type, arguments::Vector{Targets})::Targets
    return @match place begin
        Place.At(Root.Parameter(position), steps) => foldl((objects, step) -> load(flow, objects, step), steps; init = arguments[position])
        Place.At(Root.Global(binding), steps) => foldl((objects, step) -> load(flow, objects, step), steps; init = global_targets(flow, binding))
        Place.Deep(Root.Parameter(position)) => deep(flow, arguments[position])
        Place.Deep(Root.Global(binding)) => deep(flow, global_targets(flow, binding))
        # Unknown object has no place below it.
        _ => unknown(NO_DOUBT)
    end
end

"""Every origin `objects` reach through any slot, all blind; caller objects collapse to `Deep` of their root."""
function deep(flow::Flow, objects::Targets)::Targets
    found, pending = Targets(), collect(keys(objects))
    while !isempty(pending)
        origin = pop!(pending)
        reached = @match origin begin
            Origin.Caller(place) => Origin.Caller(Place.Deep(root_of(place)))
            _ => origin
        end
        add!(found, reached, BLIND_DOUBT) || continue
        for targets in contents(flow, origin)
            append!(pending, keys(targets))
        end
    end
    return found
end

"""
Call statement `index` that applies callee summary: targets of each callee parameter, callee fresh node count, callee
places mapped so far, and type sources of arguments so far. Stores of later edges miss cached places until next round,
so fixpoint stays same.
"""
struct CallSite
    arguments::Vector{Targets}
    index::Int
    fresh::Int
    places::Dict{Place.Type, Targets}
    sources::Dict{Int, Sources}
end

"""Targets of callee `place` at `site`, mapped once per call statement and round."""
site_place(flow::Flow, site::CallSite, place::Place.Type)::Targets = get!(() -> map_place(flow, place, site.arguments), site.places, place)

"""Targets of callee `node` at `site`; every fresh node of callee merges into allocation at call statement."""
function map_node(flow::Flow, node::Node.Type, site::CallSite)::Targets
    return @match node begin
        Node.Placed(place) => site_place(flow, site, place)
        Node.Fresh(_) => Targets(Origin.Allocation(site.index) => site.fresh == 1 ? NO_DOUBT : BLIND_DOUBT)
        Node.Outside() => unknown(NO_DOUBT)
    end
end

"""
Targets of each callee parameter at call `index` of `method` with `operands`. Parameters past last fixed operand take
any `Rest` element. Vararg method packs trailing operands into allocation; `Rest` elements go to its unknown slot.
"""
function parameter_targets(flow::Flow, index::Int, method::Method, operands::Vector{Operand.Type})::Vector{Targets}
    given = Targets[operand_targets(flow, operand) for operand in operands if !is_rest(operand)]
    rest = union_targets(operand_targets(flow, operand) for operand in operands if is_rest(operand))
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

"""Union of targets of callee `nodes` at `site`, each raised to its node doubt (`caller_doubt`)."""
function map_nodes(flow::Flow, nodes::Nodes, site::CallSite)::Targets
    found = Targets()
    for (node, doubt) in nodes, (origin, flag) in map_node(flow, node, site)
        add!(found, origin, most(flag, caller_doubt(flow, site, doubt)))
    end
    return found
end

"""
Callee `doubt` at `site`: each parameter source becomes type sources of its argument (`type_sources`). Parameter
without argument is doubt in code.
"""
function caller_doubt(flow::Flow, site::CallSite, doubt::Doubt)::Doubt
    sources_of(doubt) & PARAMETERS != 0 || return doubt
    sources, pending = sources_of(doubt) & ~PARAMETERS, sources_of(doubt) & PARAMETERS
    while pending != 0
        position = trailing_zeros(pending)
        pending &= pending - Sources(1)
        sources |= argument_sources(flow, site, position)
    end
    return Doubt(Level.code, sources)
end

"""Type sources of argument `position` at `site`, found once per call statement and round; doubt in code past arguments."""
function argument_sources(flow::Flow, site::CallSite, position::Int)::Sources
    position <= length(site.arguments) || return INHERENT
    haskey(site.sources, position) || (site.sources[position] = type_sources(flow, site.arguments[position]))
    return site.sources[position]
end

"""
Apply callee `summary` of `variant` at call statement `index` with `operands` (`effects.md`, Calls, steps 3 and 4):
stores and result now. Accesses go into `writes` and `reads`, or into callback record when `defers` and callable holds
caller object (`deferred`). Vararg tuple becomes allocation at `index`.
"""
function apply!(flow::Flow, writes::OriginAccesses, reads::OriginAccesses, index::Int, summary::Summary, variant::Variant, operands::Vector{Operand.Type}, defers::Bool, callees::Callees)::Nothing
    arguments = parameter_targets(flow, index, first(variant).def::Method, operands)
    site = CallSite(arguments, index, summary.fresh, Dict{Place.Type, Targets}(), Dict{Int, Sources}())
    summary.closed_world && (flow.closed_world = true)
    apply_stores!(flow, site, summary)
    if defers && deferred(arguments)
        defer!(flow, index, (variant, arguments))
    else
        apply_accesses!(flow, writes, reads, site, summary, defers, callees, Set{Deferred}())
    end
    return nothing
end

"""
Accesses of callee `summary` at `site` into `writes` and `reads`, and its callback records: record waits again when
`defers` and callable still holds caller object, else resolves here. `seen` holds records resolved at site.
"""
function apply_accesses!(flow::Flow, writes::OriginAccesses, reads::OriginAccesses, site::CallSite, summary::Summary, defers::Bool, callees::Callees, seen::Set{Deferred})::Nothing
    for (table, effects) in ((writes, summary.writes), (reads, summary.reads)), ((place, below), effect) in effects
        objects = site_place(flow, site, place)
        access!(table, below ? beneath(flow, objects) : objects, below, Effect(caller_doubt(flow, site, effect.doubt), site.index, effect.reason))
    end
    for callback in summary.callbacks
        record = (callback.variant, Targets[map_nodes(flow, nodes, site) for nodes in callback.parameters])
        defers && deferred(last(record)) ? defer!(flow, site.index, record) : resolve!(flow, writes, reads, site.index, record, defers, callees, seen)
    end
    return nothing
end

"""
Resolve callback `record` at call statement `index`: callable is fresh here, so accesses of its variant apply to record
targets. Record in `seen` adds nothing: recursion through callable repeats same accesses on same targets. Instance
that kept record took `closed_world` of variant already (`apply!`).
"""
function resolve!(flow::Flow, writes::OriginAccesses, reads::OriginAccesses, index::Int, record::Deferred, defers::Bool, callees::Callees, seen::Set{Deferred})::Nothing
    record in seen && return nothing
    push!(seen, record)
    variant, arguments = record
    summary = summary!(callees, variant)
    site = CallSite(arguments, index, summary.fresh, Dict{Place.Type, Targets}(), Dict{Int, Sources}())
    apply_accesses!(flow, writes, reads, site, summary, defers, callees, seen)
    return nothing
end

"""Keep callback `record` of call statement `index` for caller; its targets are copied, since values grow in round."""
function defer!(flow::Flow, index::Int, record::Deferred)::Nothing
    push!(get!(Vector{Deferred}, flow.callbacks, index), (first(record), map(copy, last(record))))
    return nothing
end

"""
Whether call with callee parameter `arguments` (callable first) leaves accesses to caller: callable holds object below
caller parameter, and no argument holds fresh object. Caller merges fresh objects of instance into one (`map_node`).
"""
function deferred(arguments::Vector{Targets})::Bool
    any(parameter_origin, keys(first(arguments))) || return false
    return !any(targets -> any(fresh_origin, keys(targets)), arguments)
end

"""Whether `origin` is caller object at path below parameter: caller can tell which object it is."""
parameter_origin(origin::Origin.Type)::Bool = @match origin begin
    Origin.Caller(Place.At(Root.Parameter(_), _)) => true
    _ => false
end

"""Callee stores between caller objects at `site`, global bindings and result."""
function apply_stores!(flow::Flow, site::CallSite, summary::Summary)::Nothing
    for ((node, step), nodes) in summary.edges
        store!(flow, map_node(flow, node, site), step, map_nodes(flow, nodes, site))
    end
    for (node, nodes) in summary.backing
        store_backing!(flow, map_node(flow, node, site), map_nodes(flow, nodes, site))
    end
    for (node, nodes) in summary.spread
        store!(flow, map_node(flow, node, site), nothing, map_nodes(flow, nodes, site))
    end
    for (binding, nodes) in summary.bound
        bind!(flow, binding, map_nodes(flow, nodes, site))
    end
    assign!(flow, site.index, map_nodes(flow, summary.result, site))
    return nothing
end
