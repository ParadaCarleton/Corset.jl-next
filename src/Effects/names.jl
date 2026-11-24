# Name tier walk over one unit (`effects.md`, Name trust): roots, writes, reads and call facts.

using ..StandIns: StandIns

"""
Caller-visible places one IR value can be or lie beneath (`places`), places stored inside it (`inner`: fresh object
that holds operands), whether value can be fresh object on some path (`fresh`), and whether it can hold fresh or
unknown objects that `inner` omits (`untracked`).
"""
struct Value
    places::Set{Place.Type}
    inner::Set{Place.Type}
    fresh::Bool
    untracked::Bool
end

"""Whether `first` and `second` hold same places: fixpoint test compares set contents."""
Base.:(==)(first::Value, second::Value)::Bool =
    first.fresh == second.fresh && first.untracked == second.untracked && first.places == second.places && first.inner == second.inner
"""Hash of `value` consistent with `==`."""
Base.hash(value::Value, seed::UInt)::UInt = hash(value.inner, hash(value.places, hash(value.untracked, hash(value.fresh, seed))))

"""Value that holds no caller-visible place: `isbits` result, literal, function."""
const NO_VALUE = Value(Set{Place.Type}(), Set{Place.Type}(), false, false)

"""Fresh object that holds `inner` places; `untracked` when it can hold other objects too."""
fresh_value(inner::AbstractSet{Place.Type}, untracked::Bool)::Value = Value(Set{Place.Type}(), inner, true, untracked)

"""Value that is exactly `place`."""
place_value(place::Place.Type)::Value = Value(Set{Place.Type}([place]), Set{Place.Type}(), false, false)

"""Most exact places of one root a set keeps; more collapse to `Deep` of that root (`bounded`)."""
const PLACE_LIMIT = 16

"""Whether `place` is `Deep` of its root."""
is_deep(place::Place.Type)::Bool = @match place begin
    Place.Deep(_) => true
    Place.At(_, _) => false
end

"""Whether `places` holds `Deep` of some root beside place strictly below that root, which `bounded` drops."""
covered(places::AbstractSet{Place.Type})::Bool =
    any(deep -> is_deep(deep) && any(place -> !is_deep(place) && place_root(place) == place_root(deep) && place != Place.At(place_root(deep), NO_STEPS), places), places)

"""
`places` where each root with `Deep` place or more than `PLACE_LIMIT` places keeps only root itself and `Deep` of root.
Linked structures reach many exact paths (`node.left.parent.right`); `Deep` covers them, so fixpoint sets stay finite.
"""
function bounded(places::AbstractSet{Place.Type})::Set{Place.Type}
    length(places) <= PLACE_LIMIT && !covered(places) && return places
    counts = Dict{Root.Type, Int}()
    foreach(place -> counts[place_root(place)] = is_deep(place) ? PLACE_LIMIT + 1 : get(counts, place_root(place), 0) + 1, places)
    any(>(PLACE_LIMIT), values(counts)) || return places
    wide(place::Place.Type)::Bool = counts[place_root(place)] > PLACE_LIMIT && place != Place.At(place_root(place), NO_STEPS)
    return Set{Place.Type}(wide(place) ? Place.Deep(place_root(place)) : place for place in places)
end

"""`value` with `bounded` places and inner places."""
bounded(value::Value)::Value = Value(bounded(value.places), bounded(value.inner), value.fresh, value.untracked)

"""Value either of `first` or `second` can be on its path."""
joined(first::Value, second::Value)::Value =
    Value(union(first.places, second.places), union(first.inner, second.inner), first.fresh || second.fresh, first.untracked || second.untracked)

"""Every place `value` holds or holds inside."""
held(value::Value)::Set{Place.Type} = union(value.places, value.inner)

"""Place `place` one `step` deeper; past `PATH_DEPTH` steps it collapses to `Deep` of its root."""
deeper(place::Place.Type, step::Step.Type)::Place.Type = @match place begin
    Place.At(root, steps) => length(steps) >= PATH_DEPTH ? Place.Deep(root) : Place.At(root, PlaceSteps(steps, step))
    Place.Deep(_) => place
end

"""
Value loaded one `step` below `value`: places one step deeper, and objects fresh value holds inside. Untracked object
inside is fresh or unknown, so loaded value can be fresh and untracked too.
"""
loaded(value::Value, step::Step.Type)::Value =
    Value(union(Set{Place.Type}(deeper(place, step) for place in value.places), value.inner), Set{Place.Type}(), value.untracked, value.untracked)

"""Value loaded at unknown step below `value`: `Deep` of each root, and objects fresh value holds inside."""
deep_loaded(value::Value)::Value =
    Value(union(Set{Place.Type}(Place.Deep(place_root(place)) for place in value.places), value.inner), Set{Place.Type}(), value.untracked, value.untracked)

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
Write of closure method, of `kind`: `target` is position of captured field it writes through, or global binding it
writes below. `exact` when local it writes through holds one object.
"""
struct ClosureWrite
    target::Union{Int, GlobalRef}
    kind::EffectKind.T
    exact::Bool
end

"""
IR of one unit with value of each statement, whether compiler proves each statement `effect_free` (`proven`), places
stored into each caller place (`stored`), `referent!` answers (`ir.jl`), package modules, captured field writes of each
closure type (`closure_writes!`), `effect_free` claim of each callee method or generated instance, and world dispatch
reads.
"""
struct Walk
    ir::CC.IRCode
    values::Vector{Value}
    proven::Vector{Bool}
    stored::Dict{Place.Type, Set{Place.Type}}
    referent::IdDict{Any, Bool}
    modules::Set{Module}
    closures::IdDict{Any, Vector{ClosureWrite}}
    claims::IdDict{Union{Method, Core.MethodInstance}, Bool}
    world::UInt
end

"""Value loaded below `value` in `walk`: one `step` deeper, or `Deep` of each root for unknown step; stored places too."""
function load_value(walk::Walk, value::Value, step::Union{Nothing, Step.Type})::Value
    found = isnothing(step) ? deep_loaded(value) : loaded(value, something(step))
    for place in value.places
        stored = get(walk.stored, place, nothing)
        isnothing(stored) || union!(found.places, stored)
    end
    return Value(bounded(found.places), found.inner, found.fresh, found.untracked)
end

"""Type of statement or operand `operand` in `walk`, widened."""
operand_type(walk::Walk, @nospecialize(operand::Any))::Any = value_type(walk.ir, operand)

# corset: allow bang-convention -- memo of type answers in walk; result never changes
"""Whether value of `type` can point to caller-visible object; `ScopedValue` points to its scoped state."""
pointing(walk::Walk, @nospecialize(type::Any))::Bool = referent!(walk.referent, type) || (type isa Type && type !== Union{} && type <: Base.ScopedValues.ScopedValue)

"""Value of IR `operand` in `walk`: statement value, argument place, global place, or global state for literal object."""
function operand_value(walk::Walk, @nospecialize(operand::Any))::Value
    operand isa Core.SSAValue && return walk.values[operand.id]
    pointing(walk, operand_type(walk, operand)) || return NO_VALUE
    operand isa Core.Argument && return place_value(Place.At(Root.Parameter(operand.n), NO_STEPS))
    operand isa GlobalRef && return place_value(Place.At(Root.Global(operand), NO_STEPS))
    # Mutable literal in code, such as interpolated object: global state that no binding names.
    return place_value(ELSEWHERE)
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
    return name isa Int ? Step.Position(name) : nothing
end

"""
Step that `getindex`, `first`, `last` or `only` call `callee` with `operands` loads: tuple position for constant index
into tuple, else any element. Compiler knows constant index, so position keeps objects of other positions apart.
"""
function index_step(walk::Walk, @nospecialize(callee::Any), operands::AbstractVector{Any})::Step.Type
    (callee === getindex && length(operands) == 2 && operand_type(walk, first(operands)) <: Tuple) || return Step.Element()
    found = constant(walk.ir, last(operands))
    return !isnothing(found) && something(found) isa Int ? Step.Position(something(found)) : Step.Element()
end

"""Value of IR statement `index` in `walk` from its operands (`effects.md`, Roots)."""
function statement_value(walk::Walk, index::Integer)::Value
    pointing(walk, CC.widenconst(walk.ir.stmts[index][:type])) || return NO_VALUE
    statement = walk.ir.stmts[index][:stmt]
    statement isa Core.PhiNode && return reduce(joined, (operand_value(walk, statement.values[edge]) for edge in eachindex(statement.values) if isassigned(statement.values, edge)); init = NO_VALUE)
    statement isa Core.PhiCNode && return reduce(joined, (operand_value(walk, value) for value in statement.values); init = NO_VALUE)
    statement isa Core.PiNode && return operand_value(walk, statement.val)
    statement isa Core.UpsilonNode && return isdefined(statement, :val) ? operand_value(walk, statement.val) : NO_VALUE
    statement isa Union{Core.SSAValue, Core.Argument, GlobalRef} && return operand_value(walk, statement)
    statement isa Expr || return NO_VALUE
    statement.head === :new && return holding_value(walk, statement.args[2:end])
    statement.head === :call || return statement.head === :foreigncall ? fresh_value(Set{Place.Type}(), true) : NO_VALUE
    return call_value(walk, statement, CC.widenconst(walk.ir.stmts[index][:type]))
end

"""
Fresh object that holds objects of `operands`: untracked when some operand of pointing type can be fresh, or holds no
place.
"""
function holding_value(walk::Walk, operands::AbstractVector{Any})::Value
    inner, untracked = Set{Place.Type}(), false
    for operand in operands
        value = operand_value(walk, operand)
        union!(inner, held(value))
        untracked |= pointing(walk, operand_type(walk, operand)) && (value.fresh || isempty(value.places))
    end
    return fresh_value(inner, untracked)
end

"""
Value of array literal of `type` with `elements` (`[a, b]`, `T[a, b]`). Element not of element type converts, and
conversion can give new object, so literal holds untracked objects too.
"""
function literal_value(walk::Walk, elements::AbstractVector{Any}, @nospecialize(type::Any))::Value
    holder = holding_value(walk, elements)
    exact = type isa DataType && type <: AbstractArray && all(element -> operand_type(walk, element) <: element_type(type), elements)
    return Value(holder.places, holder.inner, holder.fresh, holder.untracked || !exact)
end

"""Whether call of `callee` with `operands` dispatches to one method that `Base` owns."""
function base_method(walk::Walk, @nospecialize(callee::Any), operands::AbstractVector{Any})::Bool
    matches = Base._methods_by_ftype(Tuple{Core.Typeof(callee), Any[operand_type(walk, operand) for operand in operands]...}, 1, walk.world)
    return matches isa Vector && length(matches) == 1 && only(matches).method.module === Base
end

"""Step from container of `type` to its element: `Element` for array, dictionary, set and tuple; unknown step else."""
element_step(@nospecialize(type::Any))::Union{Nothing, Step.Type} = type <: Union{AbstractArray, AbstractDict, AbstractSet, Tuple, NamedTuple} ? Step.Element() : nothing

"""Whether objects of `type` can hold pointing objects: field or element type that points; unknown type can."""
function holds_pointing(walk::Walk, @nospecialize(type::Any))::Bool
    type isa DataType || return true
    Base.isabstracttype(type) && return true
    isnothing(element_step(type)) || return pointing(walk, element_type(type))
    return any(index -> pointing(walk, fieldtype(type, index)), 1:fieldcount(type))
end

"""
Value of call `call` with result of `type`: type assertion gives operand, field and element loads add step, alias functions keep operand places,
iteration and element functions give elements, constructors hold operands, others give fresh object.
"""
function call_value(walk::Walk, call::Expr, @nospecialize(type::Any))::Value
    callee, operands = call_parts(walk, call)
    isnothing(operands) && return fresh_value(Set{Place.Type}(), true)
    # Constructor without operands builds new object that holds nothing (`IOBuffer()`).
    isempty(operands) && return fresh_value(Set{Place.Type}(), !(callee isa Type))
    # Array literal: `[a, b]` (`vect`), or `T[a, b]` (element type operand, then elements).
    if (callee === getindex && operand_type(walk, operands[1]) <: Type) || callee === Base.vect
        # Package method on literal syntax (`SA[x]`) is package call.
        base_method(walk, callee, operands) || return new_value(walk, operands, type)
        return literal_value(walk, callee === Base.vect ? operands : operands[2:end], type)
    end
    object = operand_value(walk, operands[1])
    # Type assertion gives its operand, as on return of method with return type.
    callee === typeassert && return object
    if callee in LOAD_BUILTINS || callee === getproperty
        step = callee === getfield || callee === getproperty ? (length(operands) >= 2 ? field_step(walk, operands[2]) : nothing) : Step.Element()
        return load_value(walk, object, step)
    end
    callee in (getindex, first, last, only) && return load_value(walk, object, index_step(walk, callee, operands))
    if callee in ALIAS_FUNCTIONS
        # Result holds every operand at once (`zip(a, b)`): fresh operand leaves certainty of caller operand.
        values = Value[operand_value(walk, operand) for operand in operands if !callable(walk, operand)]
        places, inner = reduce(union, (value.places for value in values); init = Set{Place.Type}()), reduce(union, (value.inner for value in values); init = Set{Place.Type}())
        return Value(places, inner, any(value -> value.fresh && !isempty(value.places), values), any(value -> value.untracked, values))
    end
    # Iteration result: tuple of element and state.
    if callee === iterate || callee === Base.indexed_iterate
        element = load_value(walk, object, element_step(operand_type(walk, operands[1])))
        return fresh_value(element.places, element.fresh || isempty(element.places))
    end
    callee in ELEMENT_FUNCTIONS && return element_value(walk, call, callee, operands, type)
    # Every operand is an alternative, callable object too (`ifelse(flag, a, b)`).
    choices = (operand_value(walk, operand) for operand in operands)
    callee in CHOICE_FUNCTIONS && return reduce(joined, choices; init = NO_VALUE)
    # Conversion gives operand itself, or new object.
    callee === convert && return reduce(joined, choices; init = new_value(walk, operands, type))
    # Constructor and tuple results hold their operands.
    (callee isa Type || callee === Core.tuple) && return holding_value(walk, operands)
    return new_value(walk, operands, type)
end

"""
New object of `type` from call with `operands`: untracked, and holds `Deep` place below each operand whose type can
hold pointing objects (`copy`, `filter`). Type that holds no pointing object holds nothing.
"""
function new_value(walk::Walk, operands::AbstractVector{Any}, @nospecialize(type::Any))::Value
    holds_pointing(walk, type) || return fresh_value(Set{Place.Type}(), false)
    inner = Set{Place.Type}()
    for operand in operands
        holds_pointing(walk, operand_type(walk, operand)) || continue
        foreach(place -> push!(inner, Place.Deep(place_root(place))), held(operand_value(walk, operand)))
    end
    return fresh_value(inner, true)
end

"""
Value of element function call `call` of `callee` with `operands` and result of `type`. Container is first operand,
or second after leading callable or `AbstractRNG` (`get(f, d, k)`, `rand(rng, xs)`). Result is its element, or default
of lookup (`get(d, k, default)`). Result of leading callable can be fresh or captured object. Exceptions: `take!`
and `fetch` off `Channel`, `rand` with dimensions.
"""
function element_value(walk::Walk, call::Expr, @nospecialize(callee::Any), operands::AbstractVector{Any}, @nospecialize(type::Any))::Value
    Base.require_one_based_indexing(operands)
    called = callable(walk, operands[1])
    position = called || rng_operand(walk, operands[1]) ? 2 : 1
    position <= length(operands) || return fresh_value(Set{Place.Type}(), true)
    container = operand_type(walk, operands[position])
    element = load_value(walk, operand_value(walk, operands[position]), element_step(container))
    # `take!(::IOBuffer)` can share buffer or copy it; `fetch(::Task)` gives task result.
    (callee === take! || callee === fetch) && !(container <: Channel) && return joined(element, new_value(walk, operands, type))
    # Sample with dimensions gives new array of elements.
    sampled = callee === Random.rand && length(operands) > position
    sampled && return fresh_value(element.places, element.fresh || isempty(element.places))
    # Keyword reduction can give new array of elements (`dims`) or keyword value (`init`).
    keywords = keyword_value(walk, call)
    isnothing(keywords) || (element = joined(joined(element, fresh_value(element.places, true)), deep_loaded(keywords)))
    found = callee in DEFAULT_FUNCTIONS && position == 1 && length(operands) >= 3 ? joined(element, operand_value(walk, operands[3])) : element
    # Leading callable gives new object or object it captures (`get(() -> x, d, k)`).
    return called ? joined(found, joined(fresh_value(Set{Place.Type}(), true), deep_loaded(operand_value(walk, operands[1])))) : found
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
    fill!(walk.values, Value(top, top, true, true))
    foreach(place -> walk.stored[place] = top, union(top, keys(walk.stored)))
    return nothing
end

"""
Values of every statement of `ir`, to fixpoint: phi nodes read later statements, and stores put operands inside
written values (`push!(v, x)` puts `x` inside `v`): inside fresh value, or into `stored` of each caller place.
Values only grow through finite states, so loop ends; long chain needs one round per link. Past `limit` rounds, every
value widens (`widen!`), and next round must settle.
"""
function walk_values!(walk::Walk, limit::Integer)::Nothing
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
            target, contents = stored
            inner = contents.inner
            isempty(inner) && !contents.untracked && continue
            if target isa Core.SSAValue
                old = walk.values[target.id]
                merged = bounded(Value(old.places, union(old.inner, inner), old.fresh, old.untracked || contents.untracked))
                merged == old || (walk.values[target.id] = merged; changed = true)
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
Operand that statement `index` stores other operands into, and their objects as fresh holder (`holding_value`):
builtin store target or written operand of `!` call. `nothing` for other statement.
"""
function store_target(walk::Walk, index::Integer)::Union{Nothing, Tuple{Any, Value}}
    statement = walk.ir.stmts[index][:stmt]
    statement isa Expr || return nothing
    statement.head === :call || return nothing
    callee, operands = call_parts(walk, statement)
    (isnothing(operands) || isempty(operands)) && return nothing
    position = callee in STORE_BUILTINS ? 1 : bang_function(callee) ? written_position(walk, callee, operands) : nothing
    isnothing(position) && return nothing
    return operands[position], holding_value(walk, Any[operand for (other, operand) in enumerate(operands) if other != position])
end

"""Whether `callee` is function whose name ends in `!`, builtins excepted."""
bang_function(@nospecialize(callee::Any))::Bool = callee isa Function && !(callee isa Core.Builtin) && callee !== (!) && endswith(string(nameof(callee)), "!")

"""
Whether name trust lets calls of function that `method` adds to write operands (F53): `!` name, or Base function whose
calls write subject of method (`subject_position`, `exception_events`): IO function on `IO`, RNG function on
`AbstractRNG`, `iterate` on stateful iterator, synchronization function. Constructor and callable object give false.
"""
function name_writes(method::Method)::Bool
    type = Base.unwrap_unionall(method.sig).parameters[1]
    (type isa DataType && isdefined(type, :instance)) || return false
    callee = type.instance
    bang_function(callee) && return true
    position = subject_position(method)
    isnothing(position) && return false
    subject = something(argument_type(method, position))
    callee in IO_FUNCTIONS && return subject <: IO
    callee in RNG_FUNCTIONS && return subject <: AbstractRNG
    callee === iterate && return stateful_iterator(subject)
    return callee in SYNC_FUNCTIONS
end

"""
Library that owns function `callee`, for tables of functions Corset never loads: `:Base`, `:LinearAlgebra` (root module
with its package UUID), else `nothing`. Package submodule can share library name.
"""
function library_owner(@nospecialize(callee::Any))::Union{Nothing, Symbol}
    owner = parentmodule(callee)
    owner === Base && return :Base
    (Base.moduleroot(owner) === owner && Base.PkgId(owner) == LINEAR_ALGEBRA) && return :LinearAlgebra
    return nothing
end

"""
Position of operand that `!` function `callee` writes among `operands` (`effects.md`, Writes, source 2): first operand
after leading callable, `IO` and `AbstractRNG` operands, or position table entry. `nothing` when none is left.
"""
function written_position(walk::Walk, @nospecialize(callee::Any), operands::AbstractVector{Any})::Union{Nothing, Int}
    table = get(WRITE_POSITION, (nameof(callee), length(operands)), nothing)
    !isnothing(table) && library_owner(callee) === :LinearAlgebra && return table
    return next_subject(walk, operands, 1)
end

"""First position from `start` of `operands` whose operand is not callable, `IO` or `AbstractRNG`; `nothing` when none."""
function next_subject(walk::Walk, operands::AbstractVector{Any}, start::Integer)::Union{Nothing, Int}
    for position in start:lastindex(operands)
        operand = operands[position]
        (callable(walk, operand) || io_operand(walk, operand) || rng_operand(walk, operand)) && continue
        return position
    end
    return nothing
end

"""
Positions that `!` call can write instead of `written`: each subject after run of functors from `written`. `map!`
writes `r` in `map!(scale, r, x)`. Empty when operand at `written` has no call method.
"""
function functor_followers(walk::Walk, operands::AbstractVector{Any}, written::Integer)::Vector{Int}
    followers, position = Int[], written
    while functor(walk, operands[position])
        found = next_subject(walk, operands, position + 1)
        isnothing(found) && break
        position = something(found)
        push!(followers, position)
    end
    return followers
end

"""Whether value of `operand` type can have call method: functor type, its supertype, or type too wide to tell."""
function functor(walk::Walk, @nospecialize(operand::Any))::Bool
    type = operand_type(walk, operand)
    (type isa Type && type !== Union{}) || return false
    matches = Base._methods_by_ftype(Tuple{type, Vararg{Any}}, 1, walk.world)
    return !(matches isa Vector && isempty(matches))
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

"""
Events of IR statement `index` in `walk` (`effects.md`, Writes and Reads), and writes of package closures call invokes
(`closure_events`).
"""
function statement_events(walk::Walk, index::Integer)::Tuple{Vector{Event}, Vector{ClosureWrite}}
    statement = walk.ir.stmts[index][:stmt]
    statement isa GlobalRef && return global_reads(walk, statement), ClosureWrite[]
    found = Event[]
    for reference in CC.userefs(statement)
        operand = reference[]
        operand isa GlobalRef && append!(found, global_reads(walk, operand))
    end
    statement isa Expr || return found, ClosureWrite[]
    if statement.head === :foreigncall
        count = length(statement.args[3]::Core.SimpleVector)
        for operand in statement.args[6:(5 + count)]
            append!(found, (Event(event.place, true, event.kind, Confidence.possible, true) for event in value_events(walk, operand_value(walk, operand), EffectKind.memory, true, true)))
        end
    elseif statement.head === :call
        events, writes = call_events(walk, statement, index)
        return append!(found, events), writes
    end
    return found, ClosureWrite[]
end

# corset: allow bang-convention -- memo of type answers in walk; result never changes
"""Read of global `binding` (`effects.md`, Reads): non-constant binding, or constant whose value holds mutable object."""
function global_reads(walk::Walk, binding::GlobalRef)::Vector{Event}
    isconst(binding) && !referent!(walk.referent, binding_type(binding)) && return Event[]
    place = Place.At(Root.Global(binding), NO_STEPS)
    return [Event(place, false, place_kind(walk, place, EffectKind.memory), Confidence.definite, false)]
end

"""
Events of call `call`, statement `index` (`effects.md`, Writes, sources 1 to 3, 5 and 6, and Reads), and writes of
package closures it invokes. Call that compiler proves `effect_free` invokes no closure that writes caller state.
"""
function call_events(walk::Walk, call::Expr, index::Integer)::Tuple{Vector{Event}, Vector{ClosureWrite}}
    callee, operands = call_parts(walk, call)
    isnothing(operands) && return splat_events(walk, callee, call), ClosureWrite[]
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
    closures, writes = closure_events(walk, call, index, callee, operands)
    append!(found, closures)
    append!(found, read_events(walk, callee, operands))
    return found, writes
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
written operand, `possible` write on places keyword tuple holds, else on global state. Skipped operand counts as written
one: `take!(io)` writes `io` only.
"""
function bang_events(walk::Walk, @nospecialize(callee::Any), operands::AbstractVector{Any}, keywords::Union{Nothing, Value})::Vector{Event}
    Base.require_one_based_indexing(operands)
    found, position, skipped = Event[], written_position(walk, callee, operands), false
    for operand in operands[1:(something(position, length(operands) + 1) - 1)]
        io, rng = io_operand(walk, operand), rng_operand(walk, operand)
        skipped |= io || rng
        io && append!(found, value_events(walk, operand_value(walk, operand), EffectKind.io, true, true))
        rng && append!(found, value_events(walk, operand_value(walk, operand), EffectKind.rng_argument, true, true))
    end
    if isnothing(position)
        places = isnothing(keywords) ? Set{Place.Type}() : held(keywords)
        append!(found, (Event(place, true, place_kind(walk, place, EffectKind.memory), Confidence.possible, true) for place in places))
        isempty(found) && !skipped && push!(found, Event(ELSEWHERE, true, EffectKind.memory, Confidence.definite, true))
    else
        append!(found, value_events(walk, operand_value(walk, operands[something(position)]), EffectKind.memory, true, true))
    end
    return found
end

"""Events of library function without `!` that writes (`effects.md`, Writes, source 3): IO, synchronization, RNG, stateful iteration."""
function exception_events(walk::Walk, @nospecialize(callee::Any), operands::AbstractVector{Any})::Vector{Event}
    Base.require_one_based_indexing(operands)
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
    elseif callee === iterate
        append!(found, consumed_events(walk, operands[1]))
    elseif callee === isempty && length(operands) == 1
        # Generic `isempty` iterates when `isdone` can give `missing`: `zip` with stateful part consumes that part.
        writes = consumed_events(walk, operands[1])
        certainty = isempty(writes) ? nothing : isempty_start(walk, operand_type(walk, operands[1]))
        isnothing(certainty) || append!(found, (Event(write.place, write.below, write.kind, max(write.confidence, certainty), true) for write in writes))
    elseif callee in CONSUMING_FUNCTIONS || callee === first || callee === only
        foreach(operand -> append!(found, consumed_events(walk, operand)), operands)
    end
    return found
end

"""
Memory writes of iterating IR `operand` in `walk`: stateful value whole, but only stateful parts of `zip` or product
that unit builds. Part that restarts, as caller vector, takes no write. `seen` visits shared part of `zip(z, z)` once.
"""
consumed_events(walk::Walk, @nospecialize(operand::Any))::Vector{Event} = consumed_events!(Set{Any}(), walk, operand)

"""`consumed_events` that adds visited operands to `seen`."""
function consumed_events!(seen::AbstractSet{Any}, walk::Walk, @nospecialize(operand::Any))::Vector{Event}
    key = underlying(walk, operand)
    key in seen && return Event[]
    push!(seen, key)
    parts = joint_operands(walk, operand)
    isnothing(parts) || return Event[event for part in parts for event in consumed_events!(seen, walk, part)]
    stateful_iterator(operand_type(walk, operand)) || return Event[]
    return value_events(walk, operand_value(walk, operand), EffectKind.memory, true, true)
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
function read_events(walk::Walk, @nospecialize(callee::Any), operands::AbstractVector{Any})::Vector{Event}
    Base.require_one_based_indexing(operands)
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
    for position in started_positions(walk, callee, operands)
        append!(found, value_events(walk, operand_value(walk, operands[position]), EffectKind.iteration, false, false))
    end
    # `isdone` result can be `missing` or not: generic `isempty` may iterate.
    if callee === isempty && length(operands) == 1 && isempty_start(walk, operand_type(walk, operands[1])) == Confidence.possible
        starts = value_events(walk, operand_value(walk, operands[1]), EffectKind.iteration, false, false)
        append!(found, (Event(start.place, start.below, start.kind, Confidence.possible, start.write) for start in starts))
    end
    return found
end

"""
Positions of operands call of `callee` starts iterating (`effects.md`, Reads): first operand of `starts_iteration` call,
each non-callable operand of consuming call, `first` or `only`.
"""
function started_positions(walk::Walk, @nospecialize(callee::Any), operands::AbstractVector{Any})::Vector{Int}
    Base.require_one_based_indexing(operands)
    starts_iteration(walk, callee, operands) && return [1]
    (callee in CONSUMING_FUNCTIONS || callee === first || callee === only) || return Int[]
    return Int[position for position in eachindex(operands) if !callable(walk, operands[position])]
end

"""Whether `place` starts at global binding."""
global_place(place::Place.Type)::Bool = !isnothing(root_global(place))

"""
Whether call starts iteration of first operand without state: `iterate(x)`, destructuring `indexed_iterate(x, 1)`,
`first`, `only`, or generic `isempty` that surely iterates (`isempty_start`).
"""
function starts_iteration(walk::Walk, @nospecialize(callee::Any), operands::AbstractVector{Any})::Bool
    Base.require_one_based_indexing(operands)
    callee === iterate && return length(operands) == 1
    callee === Base.indexed_iterate && return length(operands) == 2 && constant_value(walk, operands[2]) == 1
    callee in START_FUNCTIONS && length(operands) == 1 || return false
    callee === isempty || return true
    return isempty_start(walk, operand_type(walk, operands[1])) == Confidence.definite
end

"""
Certainty that `isempty` on value of `type` iterates it: generic `isempty` calls `iterate` when `isdone` gives `missing`.
Both generic methods alone match gives `definite`, generic among others `possible`; `nothing` when one cannot match.
"""
function isempty_start(walk::Walk, @nospecialize(type::Any))::Union{Nothing, Confidence.T}
    emptiness = generic_match(walk, Tuple{typeof(isempty), type}, Tuple{typeof(isempty), Any})
    done = done_missing(walk, type)
    return (isnothing(emptiness) || isnothing(done)) ? nothing : max(emptiness, done)
end

"""
Certainty that `isdone` on value of `type` gives `missing`: inferred result decides, so package method counts too. `zip`
and product give it when part does and no part is done, so every part sure gives `definite`, some part `possible`.
"""
done_missing(walk::Walk, @nospecialize(type::Any))::Union{Nothing, Confidence.T} = done_missing!(IdDict{Any, Union{Nothing, Confidence.T}}(), walk, type)

"""`done_missing` of `type`; `memo` keeps answer per part type, so nested `zip(z, z)` visits each type once."""
function done_missing!(memo::IdDict{Any, Union{Nothing, Confidence.T}}, walk::Walk, @nospecialize(type::Any))::Union{Nothing, Confidence.T}
    haskey(memo, type) && return memo[type]
    parts = joint_parts(type)
    found = if isnothing(parts)
        missing_result(Base.infer_return_type(Base.isdone, Tuple{type}; world = walk.world))  # corset: allow inference-dependent -- wide result gives `possible`
    else
        answers = Union{Nothing, Confidence.T}[done_missing!(memo, walk, part) for part in parts]
        all(isnothing, answers) ? nothing : all(==(Confidence.definite), answers) ? Confidence.definite : Confidence.possible
    end
    memo[type] = found
    return found
end

"""Part types of `zip` or product type; `nothing` for other type. Open part tuple gives one `Any` part."""
function joint_parts(@nospecialize(type::Any))::Union{Nothing, Vector{Any}}
    type isa Type || return nothing
    type !== Union{} && type <: Union{Iterators.Zip, Iterators.ProductIterator} || return nothing
    parts = type isa DataType ? only(type.parameters) : Any
    return parts isa DataType && parts <: Tuple && !any(Base.isvarargtype, parts.parameters) ? Any[parts.parameters...] : Any[Any]
end

"""Certainty that call with inferred `result` type gives `missing`: `Missing` alone `definite`, union with it `possible`."""
function missing_result(@nospecialize(result::Any))::Union{Nothing, Confidence.T}
    typeintersect(result, Missing) === Union{} && return nothing
    return result <: Missing ? Confidence.definite : Confidence.possible
end

"""Certainty that call of `signature` runs method of `generic` signature: `definite` alone, `possible` among others."""
function generic_match(walk::Walk, @nospecialize(signature::Type), @nospecialize(generic::Type))::Union{Nothing, Confidence.T}
    matches = Base._methods_by_ftype(signature, -1, walk.world)
    matches isa Vector || return nothing
    any(match -> match.method.sig == generic, matches) || return nothing
    return length(matches) == 1 ? Confidence.definite : Confidence.possible
end

"""Whether compiler proves call statement `index` of `walk` with `callee` `effect_free`; claim of callee (`@assume_effects`) voids proof."""
proven_call(walk::Walk, index::Integer, call::Expr, callee::Callee.Type)::Bool = walk.proven[index] && !callee_claims(walk, call, callee)

"""
Whether method `callee` of call `call` dispatches to claims `:effect_free` (`claims_effect_free`); open callee claims
none seen. Keyword call dispatches to keyword sorter, which hides claim of keyword body, so it counts as claiming.
"""
function callee_claims(walk::Walk, call::Expr, callee::Callee.Type)::Bool
    constant_value(walk, call.args[1]) === Core.kwcall && return true
    isnothing(callee_methods(callee)) && return false
    matches = call_matches(walk, call)
    return !isnothing(matches) && any(match -> match_claims(walk, match), matches)
end

# corset: allow bang-convention -- memo of claim answers in walk; result never changes
"""
Whether method of `match` claims `:effect_free` in code compiler infers for its instance; answers cached in `walk`.
Generated method gives code per instance, so its answer is per instance. Stand-in claim only restores proof that
coverage counters void, so it counts as none.
"""
function match_claims(walk::Walk, match::Core.MethodMatch)::Bool
    match.method.module === StandIns && return false
    key = Base.hasgenerator(match.method) ? CC.specialize_method(match) : match.method
    return get!(() -> claims_effect_free(match.method, CC.retrieve_code_info(CC.specialize_method(match), walk.world)), walk.claims, key)
end
