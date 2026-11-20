using Random: AbstractRNG

"""Fields of `Task` that hold default RNG state (`TaskLocalRNG`)."""
const RNG_FIELDS = (:rngState0, :rngState1, :rngState2, :rngState3, :rngState4)

"""
Audited internal state by holder type and field (`effects.md`, Effect kinds): lazy compile of `Regex`, lazy text of
`LazyString`.
"""
const AUDITED_FIELDS = Dict{Tuple{DataType, Symbol}, EffectKind.T}(
    (Regex, :regex) => EffectKind.lazy_init,
    (LazyString, :str) => EffectKind.lazy_init,
)

"""Audited internal state by global binding: Base logging state and PCRE match contexts."""
const AUDITED_GLOBALS = Dict{GlobalRef, EffectKind.T}(
    GlobalRef(Base.CoreLogging, :_min_enabled_level) => EffectKind.audited,
    GlobalRef(Base.CoreLogging, :_global_logstate) => EffectKind.audited,
    GlobalRef(Base.PCRE, :THREAD_MATCH_CONTEXTS) => EffectKind.audited,
)

"""
Audited state by method: its memory accesses below listed root take listed kind. `unsafe_convert(Ref{BigFloat},
::BigFloatData)` rewrites stale MPFR limb pointer of its argument; `task_local_storage` writes storage of current task.
"""
const AUDITED_METHODS = Dict{Method, Pair{Root.Type, EffectKind.T}}(
    which(Base.unsafe_convert, (Type{Ref{BigFloat}}, Base.MPFR.BigFloatData)) => (Root.Parameter(3) => EffectKind.audited),
    (method => (Root.Elsewhere() => EffectKind.task_local) for method in methods(task_local_storage))...,
)

"""Kind of access to object of `type` itself: `IO`, RNG or synchronization object; `nothing` for other types."""
function special_kind(@nospecialize(type::Any))::Union{Nothing, EffectKind.T}
    type isa Type && type !== Union{} || return nothing
    type <: IO && return EffectKind.io
    type <: AbstractRNG && return EffectKind.rng_argument
    type <: Union{Base.AbstractLock, Base.GenericCondition, Base.Semaphore, Base.Event} && return EffectKind.synchronization
    return nothing
end

"""
Kind of access to `field` of object of type `holder` at access statement (`effects.md`, Effect kinds): audited field,
`Task` state (RNG, scope, other), else kind of holder type itself. `nothing` field: access to whole object or memory.
"""
function site_kind(@nospecialize(holder::Any), field::Union{Nothing, Symbol})::EffectKind.T
    holder isa DataType && !isnothing(field) && haskey(AUDITED_FIELDS, (holder, field)) && return AUDITED_FIELDS[(holder, field)]
    if holder isa Type && holder !== Union{} && holder <: Task
        field in RNG_FIELDS && return EffectKind.default_rng
        return field === :scope ? EffectKind.scoped_read : EffectKind.task_local
    end
    return something(special_kind(holder), EffectKind.memory)
end

"""Kind of access to `field` (constant operand: name or index) of object of type `holder` (`site_kind`)."""
function field_kind(@nospecialize(holder::Any), field::Union{Nothing, Some{Any}})::EffectKind.T
    name = isnothing(field) ? nothing : something(field)
    name isa Int && isconcretetype(holder) && !(holder <: Tuple) && 1 <= name <= fieldcount(holder) && return site_kind(holder, fieldname(holder, name))
    return site_kind(holder, name isa Symbol ? name : nothing)
end

"""Type of root of place in instance with IR `ir`: parameter type, or declared type of global binding."""
root_type(ir::CC.IRCode, root::Root.Type)::Any = @match root begin
    Root.Parameter(position) => position <= length(ir.argtypes) ? CC.widenconst(ir.argtypes[position]) : Any
    Root.Global(binding) => isdefinedglobal(binding.mod, binding.name) ? Core.get_binding_type(binding.mod, binding.name) : Any
    Root.Elsewhere() => Any
end

"""Type in `step` slot of object of `type`; `Any` when type has no such slot."""
function step_type(@nospecialize(type::Any), step::Step.Type)::Any
    type isa DataType || return Any
    return @match step begin
        Step.Field(name) => hasfield(type, name) ? fieldtype(type, name) : Any
        Step.Position(position) => type <: Tuple && position <= something(Base.datatype_fieldcount(type), position) ? fieldtype(type, position) : Any
        Step.Element() => type <: Union{Array, GenericMemory} ? eltype(type) : Any
    end
end

"""
Kind of memory access to `place` in instance with IR `ir` (`effects.md`, Effect kinds): first special type along path,
root first; audited global; else memory.
"""
function path_kind(ir::CC.IRCode, place::Place.Type)::EffectKind.T
    root, steps = @match place begin
        Place.At(root, steps) => (root, steps)
        Place.Deep(root) => (root, Step.Type[])
    end
    binding = @match root begin
        Root.Global(binding) => binding
        _ => nothing
    end
    !isnothing(binding) && haskey(AUDITED_GLOBALS, binding) && return AUDITED_GLOBALS[binding]
    type = root_type(ir, root)
    for step in steps
        found = special_kind(type)
        isnothing(found) || return found
        type = step_type(type, step)
    end
    return something(special_kind(type), EffectKind.memory)
end

"""
Kind of access with `kind` to `place` in instance of `method` with IR `ir`: memory access below root of audited
method takes its kind, else kind of its path.
"""
function place_kind(ir::CC.IRCode, method::Method, place::Place.Type, kind::EffectKind.T)::EffectKind.T
    kind == EffectKind.memory || return kind
    audited = get(AUDITED_METHODS, method, nothing)
    !isnothing(audited) && root_of(place) == first(audited) && return last(audited)
    return path_kind(ir, place)
end
