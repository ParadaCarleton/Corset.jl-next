# Name tier walk over one unit (`effects.md`, Name trust): roots, writes, reads and call facts.

"""
Caller-visible places one IR value can be or lie beneath (`places`), places stored inside it (`inner`: fresh object
that holds operands), and whether value can be fresh object on some path (`fresh`).
"""
struct Value
    places::Set{Place.Type}
    inner::Set{Place.Type}
    fresh::Bool
end

"""Whether `first` and `second` hold same places: fixpoint test compares set contents."""
Base.:(==)(first::Value, second::Value)::Bool = first.fresh == second.fresh && first.places == second.places && first.inner == second.inner
"""Hash of `value` consistent with `==`."""
Base.hash(value::Value, seed::UInt)::UInt = hash(value.inner, hash(value.places, hash(value.fresh, seed)))

"""Value that holds no caller-visible place: `isbits` result, literal, function."""
const NO_VALUE = Value(Set{Place.Type}(), Set{Place.Type}(), false)

"""Fresh object that holds `inner` places."""
fresh_value(inner::Set{Place.Type})::Value = Value(Set{Place.Type}(), inner, true)

"""Value that is exactly `place`."""
place_value(place::Place.Type)::Value = Value(Set{Place.Type}([place]), Set{Place.Type}(), false)

"""Most exact places of one root a set keeps; more collapse to `Deep` of that root (`bounded`)."""
const PLACE_LIMIT = 16

"""Whether `place` is `Deep` of its root."""
is_deep(place::Place.Type)::Bool = @match place begin
    Place.Deep(_) => true
    Place.At(_, _) => false
end

"""Whether `places` holds `Deep` of some root beside place strictly below that root, which `bounded` drops."""
covered(places::Set{Place.Type})::Bool =
    any(deep -> is_deep(deep) && any(place -> !is_deep(place) && place_root(place) == place_root(deep) && place != Place.At(place_root(deep), NO_STEPS), places), places)

"""
`places` where each root with `Deep` place or more than `PLACE_LIMIT` places keeps only root itself and `Deep` of root.
Linked structures reach many exact paths (`node.left.parent.right`); `Deep` covers them, so fixpoint sets stay finite.
"""
function bounded(places::Set{Place.Type})::Set{Place.Type}
    length(places) <= PLACE_LIMIT && !covered(places) && return places
    counts = Dict{Root.Type, Int}()
    foreach(place -> counts[place_root(place)] = is_deep(place) ? PLACE_LIMIT + 1 : get(counts, place_root(place), 0) + 1, places)
    any(>(PLACE_LIMIT), values(counts)) || return places
    wide(place::Place.Type)::Bool = counts[place_root(place)] > PLACE_LIMIT && place != Place.At(place_root(place), NO_STEPS)
    return Set{Place.Type}(wide(place) ? Place.Deep(place_root(place)) : place for place in places)
end

"""`value` with `bounded` places and inner places."""
bounded(value::Value)::Value = Value(bounded(value.places), bounded(value.inner), value.fresh)

"""Value either of `first` or `second` can be on its path."""
joined(first::Value, second::Value)::Value = Value(union(first.places, second.places), union(first.inner, second.inner), first.fresh || second.fresh)

"""Every place `value` holds or holds inside."""
held(value::Value)::Set{Place.Type} = union(value.places, value.inner)

"""Place `place` one `step` deeper; past `PATH_DEPTH` steps it collapses to `Deep` of its root."""
deeper(place::Place.Type, step::Step.Type)::Place.Type = @match place begin
    Place.At(root, steps) => length(steps) >= PATH_DEPTH ? Place.Deep(root) : Place.At(root, PlaceSteps(steps, step))
    Place.Deep(_) => place
end

"""Root of `place`."""
place_root(place::Place.Type)::Root.Type = @match place begin
    Place.At(root, _) => root
    Place.Deep(root) => root
end

"""Value loaded one `step` below `value`: places one step deeper, and objects fresh value holds inside."""
loaded(value::Value, step::Step.Type)::Value = Value(union(Set{Place.Type}(deeper(place, step) for place in value.places), value.inner), Set{Place.Type}(), false)

"""
Event of one statement: access to `place` of `kind` with `confidence`, covering places below (`below`), as `write` or
read.
"""
struct Event
    place::Place.Type
    below::Bool
    kind::EffectKind.T
    confidence::Confidence.T
    write::Bool
end

"""
IR of one unit with value of each statement, whether compiler proves each statement `effect_free` (`proven`), places
stored into each caller place (`stored`), `referent!` answers (`ir.jl`), package modules, captured field writes of each
closure type (`closure_writes!`), `effect_free` claim of each callee method, and world dispatch reads.
"""
struct Walk
    ir::CC.IRCode
    values::Vector{Value}
    proven::Vector{Bool}
    stored::Dict{Place.Type, Set{Place.Type}}
    referent::IdDict{Any, Bool}
    modules::Set{Module}
    closures::IdDict{Any, Vector{Pair{Int, EffectKind.T}}}
    claims::IdDict{Method, Bool}
    world::UInt
end

"""Value loaded below `value` in `walk`: one `step` deeper, or `Deep` of each root for unknown step; stored places too."""
function load_value(walk::Walk, value::Value, step::Union{Nothing, Step.Type})::Value
    found = isnothing(step) ? Value(Set{Place.Type}(Place.Deep(place_root(place)) for place in value.places), value.inner, false) : loaded(value, something(step))
    for place in value.places
        stored = get(walk.stored, place, nothing)
        isnothing(stored) || union!(found.places, stored)
    end
    return Value(bounded(found.places), found.inner, false)
end

"""Type of statement or operand `operand` in `walk`, widened."""
operand_type(walk::Walk, @nospecialize(operand::Any))::Any = value_type(walk.ir, operand)

"""Whether value of `type` can point to caller-visible object; `ScopedValue` points to its scoped state."""
pointing(walk::Walk, @nospecialize(type::Any))::Bool = referent!(walk.referent, type) || (type isa Type && type !== Union{} && type <: Base.ScopedValues.ScopedValue)

"""Value of IR `operand` in `walk`: statement value, argument place, global place, or none."""
function operand_value(walk::Walk, @nospecialize(operand::Any))::Value
    operand isa Core.SSAValue && return walk.values[operand.id]
    pointing(walk, operand_type(walk, operand)) || return NO_VALUE
    operand isa Core.Argument && return place_value(Place.At(Root.Parameter(operand.n), NO_STEPS))
    operand isa GlobalRef && return place_value(Place.At(Root.Global(operand), NO_STEPS))
    return NO_VALUE
end

"""Constant that IR `operand` holds in `walk`, or `nothing` when not constant (`constant`)."""
constant_value(walk::Walk, @nospecialize(operand::Any))::Any = (found = constant(walk.ir, operand); isnothing(found) ? nothing : something(found))

"""
Called function and its operands of call `call`: keyword call drops keyword tuple; splatted call (`_apply_iterate`)
gives `nothing` operands, since splat hides positions. `nothing` function when inference does not know callee.
"""
function call_parts(walk::Walk, call::Expr)::Tuple{Any, Union{Nothing, Vector{Any}}}
    callee = called(walk.ir, call, walk.ir.sptypes)
    head = constant_value(walk, call.args[1])
    head === Core._apply_iterate && return callee, nothing
    head === Core.kwcall && return callee, call.args[4:end]
    return callee, call.args[2:end]
end

"""Step that constant field operand `field` names: field name, tuple position, or `nothing` when not constant."""
function field_step(walk::Walk, @nospecialize(field::Any))::Union{Nothing, Step.Type}
    found = constant(walk.ir, field)
    isnothing(found) && return nothing
    name = something(found)
    name isa Symbol && return Step.Field(name)
    name isa Int && return Step.Position(name)
    return nothing
end

"""Value of IR statement `index` in `walk` from its operands (`effects.md`, Roots)."""
function statement_value(walk::Walk, index::Int)::Value
    pointing(walk, CC.widenconst(walk.ir.stmts[index][:type])) || return NO_VALUE
    statement = walk.ir.stmts[index][:stmt]
    statement isa Core.PhiNode && return reduce(joined, (operand_value(walk, statement.values[edge]) for edge in eachindex(statement.values) if isassigned(statement.values, edge)); init = NO_VALUE)
    statement isa Core.PhiCNode && return reduce(joined, (operand_value(walk, value) for value in statement.values); init = NO_VALUE)
    statement isa Core.PiNode && return operand_value(walk, statement.val)
    statement isa Core.UpsilonNode && return isdefined(statement, :val) ? operand_value(walk, statement.val) : NO_VALUE
    statement isa Union{Core.SSAValue, Core.Argument, GlobalRef} && return operand_value(walk, statement)
    statement isa Expr || return NO_VALUE
    statement.head === :new && return fresh_value(reduce(union, (held(operand_value(walk, operand)) for operand in statement.args[2:end]); init = Set{Place.Type}()))
    statement.head === :call || return statement.head === :foreigncall ? fresh_value(Set{Place.Type}()) : NO_VALUE
    return call_value(walk, statement)
end

"""Value of call `call`: field and element loads add step, alias functions keep operand places, others give fresh object."""
function call_value(walk::Walk, call::Expr)::Value
    callee, operands = call_parts(walk, call)
    (isnothing(operands) || isempty(operands)) && return fresh_value(Set{Place.Type}())
    object = operand_value(walk, operands[1])
    if callee in LOAD_BUILTINS || callee === getproperty
        step = callee === getfield || callee === getproperty ? (length(operands) >= 2 ? field_step(walk, operands[2]) : nothing) : Step.Element()
        return load_value(walk, object, step)
    end
    callee in (getindex, first, last, only) && return load_value(walk, object, Step.Element())
    if callee in ALIAS_FUNCTIONS
        # Result holds every operand at once (`zip(a, b)`): fresh operand leaves certainty of caller operand.
        values = Value[operand_value(walk, operand) for operand in operands if !callable(walk, operand)]
        return Value(reduce(union, (value.places for value in values); init = Set{Place.Type}()), reduce(union, (value.inner for value in values); init = Set{Place.Type}()), any(value -> value.fresh && !isempty(value.places), values))
    end
    # Constructor and tuple results can hold their operands.
    (callee isa Type || callee === Core.tuple) && return fresh_value(reduce(union, (held(operand_value(walk, operand)) for operand in operands); init = Set{Place.Type}()))
    return fresh_value(Set{Place.Type}())
end

"""Whether `operand` is callable by style guide order: function or type."""
callable(walk::Walk, @nospecialize(operand::Any))::Bool = (type = operand_type(walk, operand); type <: Function || type <: Type)

"""Whether `operand` type is `IO`."""
io_operand(walk::Walk, @nospecialize(operand::Any))::Bool = operand_type(walk, operand) <: IO

"""Whether `operand` type is `AbstractRNG`."""
rng_operand(walk::Walk, @nospecialize(operand::Any))::Bool = operand_type(walk, operand) <: AbstractRNG

"""
Set every value and stored set of `walk` to root and `Deep` of each root it holds anywhere, fresh: sound and settled,
since `bounded` collapses every place below to them.
"""
function widen!(walk::Walk)::Nothing
    places = Set{Place.Type}()
    foreach(value -> union!(places, held(value)), walk.values)
    for (place, stored) in walk.stored
        push!(places, place)
        union!(places, stored)
    end
    top = Set{Place.Type}(wide for place in places for wide in (Place.At(place_root(place), NO_STEPS), Place.Deep(place_root(place))))
    fill!(walk.values, Value(top, top, true))
    foreach(place -> walk.stored[place] = top, union(top, keys(walk.stored)))
    return nothing
end

"""
Values of every statement of `ir`, to fixpoint: phi nodes read later statements, and stores put operands inside
written values (`push!(v, x)` puts `x` inside `v`): inside fresh value, or into `stored` of each caller place.
Values only grow through finite states, so loop ends; long chain needs one round per link. Past `limit` rounds, every
value widens (`widen!`), and next round must settle.
"""
function walk_values!(walk::Walk, limit::Int)::Nothing
    changed, rounds, widened = true, 0, false
    while changed
        changed, rounds = false, rounds + 1
        for index in eachindex(walk.values)
            found = bounded(joined(walk.values[index], statement_value(walk, index)))
            found == walk.values[index] || (walk.values[index] = found; changed = true)
        end
        for index in eachindex(walk.values)
            stored = store_target(walk, index)
            isnothing(stored) && continue
            target, inner = stored
            isempty(inner) && continue
            if target isa Core.SSAValue
                merged = bounded(Value(walk.values[target.id].places, union(walk.values[target.id].inner, inner), walk.values[target.id].fresh))
                merged == walk.values[target.id] || (walk.values[target.id] = merged; changed = true)
            end
            for place in operand_value(walk, target).places
                old = get(walk.stored, place, NO_VALUE.places)
                issubset(inner, old) && continue
                grown = bounded(union(old, inner))
                grown == old || (walk.stored[place] = grown; changed = true)
            end
        end
        changed && rounds >= limit || continue
        widened && error("effects walk of $(walk.ir.debuginfo.def) did not settle after widening")
        widen!(walk)
        widened = true
    end
    return nothing
end

"""
Operand that statement `index` stores other operands into, and places they hold: builtin store target or written
operand of `!` call. `nothing` for other statement.
"""
function store_target(walk::Walk, index::Int)::Union{Nothing, Tuple{Any, Set{Place.Type}}}
    statement = walk.ir.stmts[index][:stmt]
    statement isa Expr || return nothing
    statement.head === :call || return nothing
    callee, operands = call_parts(walk, statement)
    (isnothing(operands) || isempty(operands)) && return nothing
    position = callee in STORE_BUILTINS ? 1 : bang_function(callee) ? written_position(walk, callee, operands) : nothing
    isnothing(position) && return nothing
    others = Set{Place.Type}(place for (other, operand) in enumerate(operands) if other != position for place in held(operand_value(walk, operand)))
    return operands[position], others
end

"""Whether `callee` is function whose name ends in `!`, builtins excepted."""
bang_function(@nospecialize(callee::Any))::Bool = callee isa Function && !(callee isa Core.Builtin) && endswith(string(nameof(callee)), "!")

"""
Position of operand that `!` function `callee` writes among `operands` (`effects.md`, Writes, source 2): first operand
after leading callable, `IO` and `AbstractRNG` operands, or position table entry. `nothing` when none is left.
"""
function written_position(walk::Walk, @nospecialize(callee::Any), operands::Vector{Any})::Union{Nothing, Int}
    table = get(WRITE_POSITION, (nameof(callee), length(operands)), nothing)
    !isnothing(table) && nameof(parentmodule(callee)) === :LinearAlgebra && return table
    for (position, operand) in enumerate(operands)
        (callable(walk, operand) || io_operand(walk, operand) || rng_operand(walk, operand)) && continue
        return position
    end
    return nothing
end

"""Type of global `binding`: value type of constant, declared type otherwise."""
function binding_type(binding::GlobalRef)::Any
    isdefinedglobal(binding.mod, binding.name) || return Any
    isconst(binding) && return typeof(getglobal(binding.mod, binding.name))
    return Core.get_binding_type(binding.mod, binding.name)
end

"""Effect kind that values of `type` give their accesses: IO, RNG, synchronization, task or `ScopedValue`; `nothing` else."""
function special_kind(@nospecialize(type::Any))::Union{Nothing, EffectKind.T}
    type isa Type || return nothing
    type === Union{} && return nothing
    type <: IO && return EffectKind.io
    type <: AbstractRNG && return EffectKind.rng_argument
    (type <: Base.AbstractLock || type <: Base.GenericCondition || type <: Base.Semaphore || type <: Threads.Event) && return EffectKind.synchronization
    type <: Task && return EffectKind.task_local
    type <: Base.ScopedValues.ScopedValue && return EffectKind.scoped_read
    return nothing
end

"""Type one `step` below values of `type`: declared field type, element type, or `Any`."""
function step_type(@nospecialize(type::Any), step::Step.Type)::Any
    type isa DataType || return Any
    return @match step begin
        Step.Field(name) => (Base.isabstracttype(type) || !hasfield(type, name)) ? Any : fieldtype(type, name)
        Step.Position(position) => (Base.isabstracttype(type) || position > fieldcount(type)) ? Any : fieldtype(type, position)
        Step.Element() => element_type(type)
    end
end

"""Type name of `AbstractArray`, which `element_type` finds among supertypes."""
const ARRAY_NAME = Base.unwrap_unionall(AbstractArray).name
"""Type name of `AbstractDict`, which `element_type` finds among supertypes."""
const DICT_NAME = Base.unwrap_unionall(AbstractDict).name

"""
Element type of tuple, array or dictionary `type`, from declared supertype `AbstractArray{T}` or `AbstractDict{K, V}`:
package `eltype` method could throw. `Any` for other type.
"""
function element_type(type::DataType)::Any
    type <: Tuple && return eltype(type)
    current = type
    while current !== Any
        parameters = current.parameters
        current.name === ARRAY_NAME && return parameters[1] isa Type ? parameters[1] : Any
        current.name === DICT_NAME && return parameters[1] isa Type && parameters[2] isa Type ? Pair{parameters[1], parameters[2]} : Any
        current = supertype(current)
    end
    return Any
end

"""Kind of access to `place` in `walk`: first special type along place path, root first; `fallback` else."""
function place_kind(walk::Walk, place::Place.Type, fallback::EffectKind.T)::EffectKind.T
    root = place_root(place)
    type = @match root begin
        Root.Parameter(position) => CC.widenconst(walk.ir.argtypes[position])
        Root.Global(binding) => binding_type(binding)
        Root.Elsewhere() => Any
    end
    special = special_kind(type)
    isnothing(special) || return something(special)
    steps = @match place begin
        Place.At(_, steps) => steps
        Place.Deep(_) => NO_STEPS
    end
    for step in steps
        type = step_type(type, step)
        special = special_kind(type)
        isnothing(special) || return something(special)
    end
    return fallback
end

"""Events of `value` places with `kind` (or kind of place path when memory): definite for one place without fresh path."""
function value_events(walk::Walk, value::Value, kind::EffectKind.T, write::Bool, below::Bool)::Vector{Event}
    confidence = length(value.places) == 1 && !value.fresh ? Confidence.definite : Confidence.possible
    return Event[Event(place, below, kind == EffectKind.memory ? place_kind(walk, place, kind) : kind, confidence, write) for place in value.places]
end

"""Global state that no binding names: default RNG, unknown writes of `!` call without operand."""
const ELSEWHERE = Place.At(Root.Elsewhere(), NO_STEPS)

"""Place of `stdout` binding, which printing without `IO` operand writes."""
const STDOUT_PLACE = Place.At(Root.Global(GlobalRef(Base, :stdout)), NO_STEPS)

"""Events of IR statement `index` in `walk` (`effects.md`, Writes and Reads)."""
function statement_events(walk::Walk, index::Int)::Vector{Event}
    statement = walk.ir.stmts[index][:stmt]
    statement isa GlobalRef && return global_reads(walk, statement)
    found = Event[]
    assigned = statement isa Expr && statement.head === :(=) ? statement.args[1] : nothing
    for reference in CC.userefs(statement)
        operand = reference[]
        operand isa GlobalRef && operand !== assigned && append!(found, global_reads(walk, operand))
    end
    statement isa Expr || return found
    if statement.head === :(=) && statement.args[1] isa GlobalRef
        push!(found, Event(Place.At(Root.Global(statement.args[1]), NO_STEPS), false, EffectKind.memory, Confidence.definite, true))
    elseif statement.head === :foreigncall
        count = length(statement.args[3]::Core.SimpleVector)
        for operand in statement.args[6:(5 + count)]
            append!(found, (Event(event.place, true, event.kind, Confidence.possible, true) for event in value_events(walk, operand_value(walk, operand), EffectKind.memory, true, true)))
        end
    elseif statement.head === :call
        append!(found, call_events(walk, statement, index))
    end
    return found
end

"""Read of global `binding` (`effects.md`, Reads): non-constant binding, or constant whose value holds mutable object."""
function global_reads(walk::Walk, binding::GlobalRef)::Vector{Event}
    isconst(binding) && !referent!(walk.referent, binding_type(binding)) && return Event[]
    place = Place.At(Root.Global(binding), NO_STEPS)
    return [Event(place, false, place_kind(walk, place, EffectKind.memory), Confidence.definite, false)]
end

"""
Events of call `call`, statement `index` (`effects.md`, Writes, sources 1 to 3, 5 and 6, and Reads). Call that
compiler proves `effect_free` invokes no closure that writes caller state.
"""
function call_events(walk::Walk, call::Expr, index::Int)::Vector{Event}
    callee, operands = call_parts(walk, call)
    isnothing(operands) && return splat_events(walk, callee, call)
    found = Event[]
    if callee in STORE_BUILTINS
        append!(found, value_events(walk, operand_value(walk, operands[1]), EffectKind.memory, true, false))
    elseif callee in GLOBAL_BUILTINS && length(operands) >= 2
        mod, name = constant(walk.ir, operands[1]), constant(walk.ir, operands[2])
        if !isnothing(mod) && !isnothing(name) && something(mod) isa Module && something(name) isa Symbol
            push!(found, Event(Place.At(Root.Global(GlobalRef(something(mod), something(name))), NO_STEPS), false, EffectKind.memory, Confidence.definite, true))
        end
    elseif callee in POINTER_STORES
        append!(found, value_events(walk, operand_value(walk, operands[1]), EffectKind.memory, true, true))
    elseif bang_function(callee)
        append!(found, bang_events(walk, callee, operands, keyword_value(walk, call)))
    else
        append!(found, exception_events(walk, callee, operands))
    end
    append!(found, closure_events(walk, call, index, callee, operands))
    append!(found, read_events(walk, callee, operands))
    return found
end

"""Events of splatted call: `!` callee or exception callee writes every operand place, `possible`: splat hides positions."""
function splat_events(walk::Walk, @nospecialize(callee::Any), call::Expr)::Vector{Event}
    (bang_function(callee) || callee in IO_FUNCTIONS || callee in SYNC_FUNCTIONS) || return Event[]
    values = (operand_value(walk, operand) for operand in call.args[4:end])
    return Event[Event(Place.Deep(place_root(place)), true, EffectKind.memory, Confidence.possible, true) for value in values for place in held(value)]
end

"""Value of keyword tuple of keyword call `call`; `nothing` for other call."""
keyword_value(walk::Walk, call::Expr)::Union{Nothing, Value} = constant_value(walk, call.args[1]) === Core.kwcall && length(call.args) >= 2 ? operand_value(walk, call.args[2]) : nothing

"""
Events of `!` call (`effects.md`, Writes, source 2): skipped `IO` and RNG operands, then written operand. Without
written operand, `possible` write on places keyword tuple holds, else on global state.
"""
function bang_events(walk::Walk, @nospecialize(callee::Any), operands::Vector{Any}, keywords::Union{Nothing, Value})::Vector{Event}
    found, position = Event[], written_position(walk, callee, operands)
    for operand in operands[1:(something(position, length(operands) + 1) - 1)]
        io_operand(walk, operand) && append!(found, value_events(walk, operand_value(walk, operand), EffectKind.io, true, true))
        rng_operand(walk, operand) && append!(found, value_events(walk, operand_value(walk, operand), EffectKind.rng_argument, true, true))
    end
    if isnothing(position)
        places = isnothing(keywords) ? Set{Place.Type}() : held(keywords)
        append!(found, (Event(place, true, place_kind(walk, place, EffectKind.memory), Confidence.possible, true) for place in places))
        isempty(found) && push!(found, Event(ELSEWHERE, true, EffectKind.memory, Confidence.definite, true))
    else
        append!(found, value_events(walk, operand_value(walk, operands[something(position)]), EffectKind.memory, true, true))
    end
    return found
end

"""Events of library function without `!` that writes (`effects.md`, Writes, source 3): IO, synchronization, RNG, stateful iteration."""
function exception_events(walk::Walk, @nospecialize(callee::Any), operands::Vector{Any})::Vector{Event}
    found = Event[]
    if callee in IO_FUNCTIONS
        streams = [operand for operand in operands if io_operand(walk, operand)]
        for operand in streams
            append!(found, value_events(walk, operand_value(walk, operand), EffectKind.io, true, true))
        end
        isempty(streams) && callee in STDOUT_FUNCTIONS && push!(found, Event(STDOUT_PLACE, true, EffectKind.io, Confidence.definite, true))
    elseif callee in SYNC_FUNCTIONS
        resource = findfirst(operand -> !callable(walk, operand), operands)
        isnothing(resource) || append!(found, value_events(walk, operand_value(walk, operands[resource]), EffectKind.synchronization, true, false))
    elseif callee in RNG_FUNCTIONS
        generators = [operand for operand in operands if rng_operand(walk, operand)]
        for operand in generators
            append!(found, value_events(walk, operand_value(walk, operand), EffectKind.rng_argument, true, false))
        end
        isempty(generators) && push!(found, Event(ELSEWHERE, false, EffectKind.default_rng, Confidence.definite, true), Event(ELSEWHERE, false, EffectKind.default_rng, Confidence.definite, false))
    elseif callee === iterate && stateful_iterator(operand_type(walk, operands[1]))
        append!(found, value_events(walk, operand_value(walk, operands[1]), EffectKind.memory, true, true))
    elseif callee in CONSUMING_FUNCTIONS || callee === first || callee === only
        for operand in operands
            stateful_iterator(operand_type(walk, operand)) && append!(found, value_events(walk, operand_value(walk, operand), EffectKind.memory, true, true))
        end
    end
    return found
end

"""
Whether `type` iterates by removing elements (`STATEFUL_ITERATORS`, `eachline` result), or wraps such iterator:
`Iterators` wrapper or generator whose parameter is one, or `Iterators.flatten` of them. `iterate` on it writes
iterator or below.
"""
function stateful_iterator(@nospecialize(type::Any))::Bool
    type isa Type || return false
    any(stateful -> type <: stateful, STATEFUL_ITERATORS) && return true
    type isa DataType || return false
    nameof(type) === :EachLine && parentmodule(type) === Base && return true
    (parentmodule(type) === Base.Iterators || type <: Base.Generator) || return false
    # `Zip` holds its iterator types in tuple parameter; `Flatten` consumes elements of its iterator.
    # Element type from Base containers only: package `eltype` method can throw.
    nameof(type) === :Flatten && any(parameter -> parameter isa Type && (parameter <: Array || parameter <: Tuple) && stateful_iterator(eltype(parameter)), type.parameters) && return true
    return any(parameter -> stateful_iterator(parameter) || (parameter isa DataType && parameter <: Tuple && any(stateful_iterator, parameter.parameters)), type.parameters)
end

"""
Read events of call (`effects.md`, Reads): field and element loads, `ScopedValue` and task-local reads, and iteration
starts. Facts keep reads of globals and special kinds; plain argument reads stay out.
"""
function read_events(walk::Walk, @nospecialize(callee::Any), operands::Vector{Any})::Vector{Event}
    found = Event[]
    isempty(operands) && return callee in TASK_FUNCTIONS ? [Event(ELSEWHERE, false, EffectKind.task_local, Confidence.definite, false)] : found
    object = operand_value(walk, operands[1])
    scoped = operand_type(walk, operands[1]) <: Base.ScopedValues.ScopedValue
    if scoped && (callee === getindex || callee === Base.ScopedValues.get)
        append!(found, value_events(walk, object, EffectKind.scoped_read, false, false))
    elseif callee in LOAD_BUILTINS || callee === getproperty || callee === getindex
        append!(found, (event for event in value_events(walk, object, EffectKind.memory, false, false) if global_place(event.place)))
    elseif callee in TASK_FUNCTIONS
        push!(found, Event(ELSEWHERE, false, EffectKind.task_local, Confidence.definite, false))
    end
    if starts_iteration(walk, callee, operands)
        append!(found, value_events(walk, object, EffectKind.iteration, false, false))
    elseif callee in CONSUMING_FUNCTIONS || callee === first || callee === only
        for operand in operands
            callable(walk, operand) || append!(found, value_events(walk, operand_value(walk, operand), EffectKind.iteration, false, false))
        end
    end
    return found
end

"""Whether `place` starts at global binding."""
global_place(place::Place.Type)::Bool = !isnothing(root_global(place))

"""
Whether call starts iteration of first operand without state: `iterate(x)`, destructuring `indexed_iterate(x, 1)`,
`first`, `only`, or `isempty` by generic method.
"""
function starts_iteration(walk::Walk, @nospecialize(callee::Any), operands::Vector{Any})::Bool
    callee === iterate && return length(operands) == 1
    callee === Base.indexed_iterate && return length(operands) == 2 && constant_value(walk, operands[2]) == 1
    callee in START_FUNCTIONS && length(operands) == 1 || return false
    callee === isempty || return true
    matches = Base._methods_by_ftype(Tuple{typeof(isempty), operand_type(walk, operands[1])}, 1, walk.world)
    return matches isa Vector && length(matches) == 1 && only(matches).method.sig == Tuple{typeof(isempty), Any}
end

"""
Writes of package closures that call `call`, statement `index`, of `callee` with `operands` can invoke (`effects.md`,
Writes, source 5): closure body writes through captured fields map onto operands its `new` statement captured.
"""
function closure_events(walk::Walk, call::Expr, index::Int, @nospecialize(callee::Any), operands::Vector{Any})::Vector{Event}
    found, closures = Event[], filter(!isnothing, Union{Nothing, Expr}[closure_new(walk, operand) for operand in invoked_operands(walk, call, callee, operands)])
    # Compiler proof of call holds unless callee claims it (`@assume_effects`).
    isempty(closures) && return found
    walk.proven[index] && !callee_claims(walk, call, call_callee(walk, call)) && return found
    for built in closures
        for (field, kind) in closure_writes!(walk, constant_value(walk, built.args[1])::DataType)
            field + 1 <= length(built.args) || continue
            append!(found, value_events(walk, operand_value(walk, built.args[field + 1]), kind, true, true))
        end
    end
    return found
end

"""
Operands that call `call` of `callee` can invoke: called function, and operands of function that calls its function
arguments. Builtin, constructor, tuple and alias function return or store operands; `!` call stores operands after
written one.
"""
function invoked_operands(walk::Walk, call::Expr, @nospecialize(callee::Any), operands::Vector{Any})::Vector{Any}
    invoked = Any[call.args[1]]
    constant_value(walk, call.args[1]) === Core.kwcall && length(call.args) >= 3 && push!(invoked, call.args[3])
    (callee isa Core.Builtin || callee isa Type || callee === Core.tuple || callee in ALIAS_FUNCTIONS) && return invoked
    written = bang_function(callee) ? written_position(walk, callee, operands) : nothing
    return append!(invoked, operands[1:(something(written, length(operands) + 1) - 1)])
end

"""
Whether method `callee` of call `call` dispatches to claims `:effect_free` (`claims_effect_free`); open callee claims
none seen. Keyword call dispatches to keyword sorter, which hides claim of keyword body, so it counts as claiming.
"""
callee_claims(walk::Walk, call::Expr, callee::Callee.Type)::Bool = constant_value(walk, call.args[1]) === Core.kwcall || methods_claim(walk, callee)

"""Whether some method of `callee` claims `:effect_free`; answers cached in `walk`."""
function methods_claim(walk::Walk, callee::Callee.Type)::Bool
    methods = callee_methods(callee)
    return !isnothing(methods) && any(method -> get!(() -> claims_effect_free(method), walk.claims, method), methods)
end

"""`new` statement of package closure that IR `operand` holds; `nothing` for other operand."""
function closure_new(walk::Walk, @nospecialize(operand::Any))::Union{Nothing, Expr}
    operand isa Core.SSAValue || return nothing
    built = walk.ir.stmts[operand.id][:stmt]
    built isa Expr || return nothing
    built.head === :new || return nothing
    type = constant_value(walk, built.args[1])
    return type isa DataType && type <: Function && parentmodule(type) in walk.modules ? built : nothing
end

"""
Captured fields of closure `type` that its methods write, by field position, with effect kind: `!` call or builtin
store on captured field or below it, in lowered code. Lowered code has no types: callable skip reads constant callees.
"""
function closure_writes!(walk::Walk, type::DataType)::Vector{Pair{Int, EffectKind.T}}
    haskey(walk.closures, type) && return walk.closures[type]
    walk.closures[type] = Pair{Int, EffectKind.T}[]
    found = Pair{Int, EffectKind.T}[]
    # `methods(type)` lists constructors; call methods match call signature of closure instance.
    matches = Base._methods_by_ftype(Tuple{type, Vararg{Any}}, -1, walk.world)
    for method in (matches isa Vector ? Method[(match::Core.MethodMatch).method for match in matches] : Method[])
        method.source === nothing && continue
        code = Base.uncompressed_ast(method)
        captured, slots = Dict{Int, Int}(), Dict{Int, Int}()
        for (index, statement) in enumerate(code.code)
            # Local that holds captured field: `out = self.out` before `push!(out, x)`.
            if statement isa Expr && statement.head === :(=) && statement.args[1] isa Core.SlotNumber && statement.args[2] isa Core.SSAValue
                field = get(captured, (statement.args[2]::Core.SSAValue).id, nothing)
                isnothing(field) || (slots[(statement.args[1]::Core.SlotNumber).id] = field)
            end
            statement isa Expr || continue
            statement.head === :call || continue
            callee = lowered_callee(code, statement.args[1])
            if callee === getfield || callee === getproperty || callee === getindex
                source = statement.args[2]
                field = source isa Core.SlotNumber && source.id == 1 && length(statement.args) >= 3 ? captured_field(type, statement.args[3]) : captured_source(captured, slots, source)
                isnothing(field) || (captured[index] = field)
            elseif callee === setfield! || bang_function(callee)
                operands = statement.args[2:end]
                written = findfirst(operand -> !(lowered_callee(code, operand) isa Union{Function, Type}), operands)
                isnothing(written) && continue
                field = captured_source(captured, slots, operands[written])
                isnothing(field) || push!(found, field => EffectKind.memory)
            end
        end
    end
    walk.closures[type] = unique!(found)
    return walk.closures[type]
end

"""Captured field that lowered `operand` holds: statement in `captured` or local in `slots`; `nothing` else."""
function captured_source(captured::Dict{Int, Int}, slots::Dict{Int, Int}, @nospecialize(operand::Any))::Union{Nothing, Int}
    operand isa Core.SSAValue && return get(captured, operand.id, nothing)
    operand isa Core.SlotNumber && operand.id != 1 && return get(slots, operand.id, nothing)
    return nothing
end

"""Value of lowered operand `operand` of `code` when it names constant global, directly or by statement; `nothing` else."""
function lowered_callee(code::Core.CodeInfo, @nospecialize(operand::Any))::Any
    operand isa Core.SSAValue && return lowered_callee(code, code.code[operand.id])
    operand isa GlobalRef && return isdefinedglobal(operand.mod, operand.name) && isconst(operand) ? getglobal(operand.mod, operand.name) : nothing
    operand isa QuoteNode && return operand.value
    return nothing
end

"""Position of field of closure `type` that lowered field operand `name` names; `nothing` for other operand."""
function captured_field(type::DataType, @nospecialize(name::Any))::Union{Nothing, Int}
    name isa QuoteNode && (name = name.value)
    name isa Symbol || return nothing
    position = findfirst(==(name), fieldnames(type))
    # `Core.Box` field holds local variable that closure reassigns; caller cannot see that write.
    return isnothing(position) || fieldtype(type, position) === Core.Box ? nothing : position
end
