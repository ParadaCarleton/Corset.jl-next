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
Transfer call statement `index` by its `outcome`; `summary_of(index, member)` gives summary of variant that call at
`index` reaches through its `member`-th matching method.
"""
function call!(flow::Flow, index::Int, outcome::Outcome.Type, summary_of::Function)::Nothing
    @match outcome begin
        Outcome.Builtin(builtin, operands) => builtin!(flow, index, builtin, operands)
        Outcome.Intrinsic(intrinsic, operands) => intrinsic!(flow, index, intrinsic, operands)
        Outcome.Foreign(effects, operands) => table!(flow, index, effects, operands)
        Outcome.Dispatch(instances, operands) => dispatch!(flow, index, instances, operands, summary_of)
        Outcome.Contract(effects, operands, breached) => contract!(flow, index, effects, operands, breached)
        Outcome.Open(operands) => open!(flow, index, operands)
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
    foreach(position -> assign!(flow, index, beneath(flow, targets(position)), Doubt.code), effects.aliases)
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
        access!(flow.writes, objects, false, Effect(Doubt.code, index, ""))
    end
    return nothing
end

"""
Transfer call that reaches `instances` (`effects.md`, Calls, steps 3 and 5): one applies its summary; more join their
summaries. Access every member makes keeps most doubt among them; access only some make is at least `possible`.
"""
function dispatch!(flow::Flow, index::Int, instances::Vector{Core.MethodInstance}, operands::Vector{Operand.Type}, summary_of::Function)::Nothing
    if length(instances) == 1
        apply!(flow, flow.writes, flow.reads, index, summary_of(index, 1), only(instances), operands)
        return nothing
    end
    flow.closed_world = true
    writes, reads = [OriginAccesses() for _ in instances], [OriginAccesses() for _ in instances]
    for (member, instance) in enumerate(instances)
        apply!(flow, writes[member], reads[member], index, summary_of(index, member), instance, operands)
    end
    join_accesses!(flow.writes, writes)
    join_accesses!(flow.reads, reads)
    return nothing
end

"""Record in `table` join of accesses of each member in `members`: access absent from some member is at least `code`."""
function join_accesses!(table::OriginAccesses, members::Vector{OriginAccesses})::Nothing
    for key in union(keys.(members)...)
        found = [member[key] for member in members if haskey(member, key)]
        effect = reduce((first, second) -> second.doubt > first.doubt ? second : first, found)
        length(found) == length(members) || (effect = Effect(most(effect.doubt, Doubt.code), effect.cause, effect.reason))
        table[key] = haskey(table, key) ? stronger(table[key], effect) : effect
    end
    return nothing
end

"""Constant value of call `operand`; `nothing` when not constant."""
function operand_constant(flow::Flow, operand::Operand.Type)::Union{Nothing, Some{Any}}
    return @match operand begin
        Operand.Value(value) => constant(flow.ir, value)
        Operand.Part(_, _) => nothing
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
        isnothing(binding) ? assign!(flow, index, unknown()) : read_global!(flow, index, something(binding))
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
        for position in eachindex(operands)
            store!(flow, flow.values[index], Step.Position(position), targets(position))
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
        assign!(flow, index, unknown())
    elseif !(builtin in INERT_BUILTINS)
        # Definition builtins (`_structtype`, `declare_global`) change global state; outside call resolution they stay open.
        open!(flow, index, operands)
    end
    return nothing
end

"""Place of global `binding` as targets: write to binding writes it."""
global_place(binding::GlobalRef)::Targets = Targets(Origin.Caller(Place.At(Root.Global(binding), Step.Type[])) => Doubt.none)

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
        open_effects!(flow, index, reached)
        union_targets((raised(reached, Doubt.code), unknown()))
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
        write!(flow, index, shape, operands, unknown(), unknown(), values -> store!(flow, unknown(), nothing, values), Any)
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
        open!(flow, index, operands)
    elseif intrinsic === intrinsics.cglobal
        assign!(flow, index, unknown())
    else
        # Pointer arithmetic and `bitcast` keep pointer into same object.
        assign!(flow, index, union_targets(operand_targets(flow, operand) for operand in operands))
    end
    return nothing
end

"""Possible write and read below every origin of `objects` that open call at statement `index` reaches."""
function open_effects!(flow::Flow, index::Int, objects::Targets)::Nothing
    effect, reached = Effect(Doubt.code, index, ""), beneath(flow, objects)
    access!(flow.writes, reached, true, effect)
    access!(flow.reads, reached, true, effect)
    return nothing
end

"""
Transfer open call (`effects.md`, Calls, step 7): possible write and read below every operand; result may point into
operands, one direction, and to unknown object.
"""
function open!(flow::Flow, index::Int, operands::Vector{Operand.Type})::Nothing
    objects = union_targets(operand_targets(flow, operand) for operand in operands)
    open_effects!(flow, index, objects)
    assign!(flow, index, union_targets((objects, unknown())), Doubt.code)
    return nothing
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
        _ => unknown()
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
        add!(found, reached, Doubt.blind) || continue
        for targets in contents(flow, origin)
            append!(pending, keys(targets))
        end
    end
    return found
end

"""
Call statement `index` that applies callee summary: targets of each callee parameter, callee fresh node count, and
callee places mapped so far. Stores of later edges miss cached places until next round, so fixpoint stays same.
"""
struct CallSite
    arguments::Vector{Targets}
    index::Int
    fresh::Int
    places::Dict{Place.Type, Targets}
end

"""Targets of callee `place` at `site`, mapped once per call statement and round."""
site_place(flow::Flow, site::CallSite, place::Place.Type)::Targets = get!(() -> map_place(flow, place, site.arguments), site.places, place)

"""Targets of callee `node` at `site`; every fresh node of callee merges into allocation at call statement."""
function map_node(flow::Flow, node::Node.Type, site::CallSite)::Targets
    return @match node begin
        Node.Placed(place) => site_place(flow, site, place)
        Node.Fresh(_) => Targets(Origin.Allocation(site.index) => site.fresh == 1 ? Doubt.none : Doubt.blind)
        Node.Outside() => unknown()
    end
end

"""Targets of each callee parameter at call `index` of `method`: vararg method packs trailing `given` into allocation."""
function parameter_targets(flow::Flow, index::Int, method::Method, given::Vector{Targets})::Vector{Targets}
    method.isva || return given
    vararg = Targets(Origin.Allocation(index) => Doubt.none)
    for (position, targets) in enumerate(given[method.nargs:end])
        store!(flow, vararg, Step.Position(position), targets)
    end
    return [given[1:(method.nargs - 1)]; vararg]
end

"""Union of targets of callee `nodes` at `site`, each raised to its node doubt."""
function map_nodes(flow::Flow, nodes::Nodes, site::CallSite)::Targets
    found = Targets()
    for (node, doubt) in nodes, (origin, flag) in map_node(flow, node, site)
        add!(found, origin, most(flag, doubt))
    end
    return found
end

"""
Apply callee `summary` of `instance` at call statement `index` with `operands` (`effects.md`, Calls, step 3): effects
on mapped places into `writes` and `reads`, callee stores between caller objects, and result. Vararg tuple becomes
allocation at `index`.
"""
function apply!(flow::Flow, writes::OriginAccesses, reads::OriginAccesses, index::Int, summary::Summary, instance::Core.MethodInstance, operands::Vector{Operand.Type})::Nothing
    arguments = parameter_targets(flow, index, instance.def::Method, [operand_targets(flow, operand) for operand in operands])
    site = CallSite(arguments, index, summary.fresh, Dict{Place.Type, Targets}())
    summary.closed_world && (flow.closed_world = true)
    for (table, effects) in ((writes, summary.writes), (reads, summary.reads)), ((place, below), effect) in effects
        objects = site_place(flow, site, place)
        access!(table, below ? beneath(flow, objects) : objects, below, Effect(effect.doubt, index, effect.reason))
    end
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
    assign!(flow, index, map_nodes(flow, summary.result, site))
    return nothing
end
