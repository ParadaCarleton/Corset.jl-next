using Random: Random, AbstractRNG
using Scratch: Scratch
using Serialization: Serialization, AbstractSerializer

"""Fields of `Task` that hold default RNG state (`TaskLocalRNG`)."""
const RNG_FIELDS = (:rngState0, :rngState1, :rngState2, :rngState3, :rngState4)

"""
Scheduler state of `Task`: Base `wait`, `yield` and `schedule` change these fields of current task, and hand value or
exception to task they wake through `result`. Package write to them changes task state.
"""
const SCHEDULER_FIELDS = (:next, :queue, :donenotify, :result, :_state, :sticky, :priority, :_isexception, :metrics_enabled, :first_enqueued_at, :last_started_running_at, :running_time_ns, :finished_at)

"""
Audited internal state by holder type and field (`engine.md`, Effect kinds): lazy compile of `Regex`, lazy text of
`LazyString`.
"""
const AUDITED_FIELDS = Dict{Tuple{DataType, Symbol}, EffectKind.T}(
    (Regex, :regex) => EffectKind.lazy_init,
    (LazyString, :str) => EffectKind.lazy_init,
)

"""
Stream state of `AbstractSerializer`: fields that generic Serialization methods change as stream moves
(`serialize_cycle`, `reset_state`, `readheader`). Subtype that keeps other data there breaks interface.
"""
const SERIALIZER_FIELDS = (:io, :counter, :table, :pending_refs, :version)

"""
Audited kind of `field` of object of `type`: serializer stream state (IO; `Serializer` adds object cache
`known_object_data`), else `AUDITED_FIELDS` entry, else `nothing`. Other fields of package serializer keep memory kind.
"""
function audited_field(@nospecialize(type::Any), field::Symbol)::Union{Nothing, EffectKind.T}
    type isa DataType || return nothing
    stream = field in SERIALIZER_FIELDS || (type <: Serialization.Serializer && field === :known_object_data)
    type <: AbstractSerializer && stream && return EffectKind.io
    return get(AUDITED_FIELDS, (type, field), nothing)
end

"""
Audited internal state by global binding, for methods of its own package (`path_kind`): Base logging state and PCRE
match contexts. IO bookkeeping: temporary path cleanup at exit, libuv handles kept alive, include record of precompile
output, hourly timer of scratch usage log. Lazy caches: parsed TOML, loading, docstring modules, stack trace colors.
Synchronization: task queues that `wait`, `yield` and `schedule` change.
"""
const AUDITED_GLOBALS = Dict{GlobalRef, EffectKind.T}(
    GlobalRef(Base.CoreLogging, :_min_enabled_level) => EffectKind.audited,
    GlobalRef(Base.CoreLogging, :_global_logstate) => EffectKind.audited,
    GlobalRef(Base.PCRE, :THREAD_MATCH_CONTEXTS) => EffectKind.audited,
    GlobalRef(Base.Filesystem, :TEMP_CLEANUP) => EffectKind.io,
    GlobalRef(Base.Filesystem, :TEMP_CLEANUP_MAX) => EffectKind.io,
    GlobalRef(Base, :uvhandles) => EffectKind.io,
    GlobalRef(Base, :_require_dependencies) => EffectKind.io,
    GlobalRef(Scratch, :scratch_access_timers) => EffectKind.io,
    GlobalRef(Base, :TOML_CACHE) => EffectKind.lazy_init,
    GlobalRef(Base, :LOADING_CACHE) => EffectKind.lazy_init,
    GlobalRef(Base.Docs, :modules) => EffectKind.lazy_init,
    GlobalRef(Base, :STACKTRACE_FIXEDCOLORS) => EffectKind.lazy_init,
    GlobalRef(Base, :STACKTRACE_MODULECOLORS) => EffectKind.lazy_init,
    GlobalRef(Base, :Workqueues) => EffectKind.synchronization,
    GlobalRef(Base.Partr, :heaps) => EffectKind.synchronization,
)

"""Argument types of audited method (`AUDITED_METHODS`) that every instance has."""
const ANY_ARGUMENTS = Tuple{Vararg{Any}}

"""Kinds that audit of method (`Audit`) takes over: most audits take over memory accesses only."""
const MEMORY = (EffectKind.memory,)

"""
Audit of method (`AUDITED_METHODS`): access of its instance below `root` with kind in `from` takes `kind`, when
instance argument types (after callee) fall in `arguments`.
"""
struct Audit
    arguments::Type
    root::Root.Type
    from::Tuple{Vararg{EffectKind.T}}
    kind::EffectKind.T
end

"""
Audited state by method. `unsafe_convert(Ref{BigFloat}, ::BigFloatData)` rewrites stale MPFR limb pointer of its
argument; `task_local_storage` writes storage of current task. Logging: `env_override_minlevel` caches parsed
`JULIA_DEBUG` in captured boxes; `_depwarn` reads frames of backtrace. `pkgversion` caches version in package origin
record; other writes of origins (`set_pkgorigin_version_path`) stay memory. `ScopedValues.get` reads dictionary of
current task scope; only `ScopedValue` argument runs no package code (package `getdefault` does). `seed!(seed)` reseeds
default RNG and copies it into its seed record in task storage (`get_tls_seed`); package integer seed runs package code.
"""
const AUDITED_METHODS = Dict{Method, Audit}(
    which(Base.unsafe_convert, (Type{Ref{BigFloat}}, Base.MPFR.BigFloatData)) => Audit(ANY_ARGUMENTS, Root.Parameter(3), MEMORY, EffectKind.audited),
    (method => Audit(ANY_ARGUMENTS, Root.Elsewhere(), MEMORY, EffectKind.task_local) for method in methods(task_local_storage))...,
    which(Base.CoreLogging.env_override_minlevel, (Any, Any)) => Audit(ANY_ARGUMENTS, Root.Elsewhere(), MEMORY, EffectKind.audited),
    which(Base._depwarn, (Any, Any, Bool)) => Audit(ANY_ARGUMENTS, Root.Elsewhere(), MEMORY, EffectKind.audited),
    which(pkgversion, (Module,)) => Audit(ANY_ARGUMENTS, Root.Global(GlobalRef(Base, :pkgorigins)), MEMORY, EffectKind.lazy_init),
    which(Base.ScopedValues.get, (Base.ScopedValues.AbstractScopedValue,)) => Audit(Tuple{Base.ScopedValues.ScopedValue}, Root.Elsewhere(), MEMORY, EffectKind.scoped_read),
    which(Random.seed!, (Any,)) => Audit(Tuple{Union{Nothing, Base.BitInteger}}, Root.Elsewhere(), (EffectKind.memory, EffectKind.rng_argument, EffectKind.task_local), EffectKind.default_rng),
)

"""Kind of access to object of `type` itself: `IO`, RNG or synchronization object; `nothing` for other types."""
function special_kind(@nospecialize(type::Any))::Union{Nothing, EffectKind.T}
    type isa Type && type !== Union{} || return nothing
    type <: IO && return EffectKind.io
    type <: AbstractRNG && return EffectKind.rng_argument
    type <: Union{Base.AbstractLock, Base.GenericCondition, Base.Semaphore, Base.Event} && return EffectKind.synchronization
    return nothing
end

"""Base property accessors: call of one is field access of its caller (`scheduler_access`)."""
const PROPERTY_ACCESSORS = (:getproperty, :setproperty!, :modifyproperty!, :replaceproperty!, :swapproperty!, :setpropertyonce!)

"""
Whether instance of `method` accesses scheduler fields of `Task` as scheduler (`SCHEDULER_FIELDS`): Base method other
than property accessor.
"""
scheduler_method(method::Method)::Bool = Base.moduleroot(method.module) === Base && !(method.name in PROPERTY_ACCESSORS)

"""Whether `field` of object of type `holder` is scheduler field of `Task` (`SCHEDULER_FIELDS`)."""
scheduler_field(@nospecialize(holder::Any), field::Union{Nothing, Symbol})::Bool = holder isa Type && holder !== Union{} && holder <: Task && field in SCHEDULER_FIELDS

"""
Kinds whose access on `Elsewhere` names no object caller stored outside: `Task` state names current task (`site_kind`).
Audited internal state names Base object: scheduler fields of current task, logging cache, frames of deprecation.
"""
const UNMAPPED_KINDS = (EffectKind.default_rng, EffectKind.scoped_read, EffectKind.task_local, EffectKind.audited)

"""
Kind of access to `field` of object of type `holder` at access statement (`engine.md`, Effect kinds): audited field,
`Task` state (RNG, scope, other), else kind of holder type itself. `nothing` field: access to whole object or memory.
Statement of `scheduler` instance (`scheduler_method`) accesses scheduler fields of `Task` as audited state.
"""
function site_kind(@nospecialize(holder::Any), field::Union{Nothing, Symbol}, scheduler::Bool)::EffectKind.T
    audited = isnothing(field) ? nothing : audited_field(holder, field)
    isnothing(audited) || return audited
    scheduler && scheduler_field(holder, field) && return EffectKind.audited
    if holder isa Type && holder !== Union{} && holder <: Task
        field in RNG_FIELDS && return EffectKind.default_rng
        return field === :scope ? EffectKind.scoped_read : EffectKind.task_local
    end
    return something(special_kind(holder), EffectKind.memory)
end

"""
Kind of access to `field` (constant operand: name or index) of object of type `holder` in `scheduler` instance or
other (`site_kind`).
"""
function field_kind(@nospecialize(holder::Any), field::Union{Nothing, Some{Any}}, scheduler::Bool)::EffectKind.T
    name = isnothing(field) ? nothing : something(field)
    name isa Int && isconcretetype(holder) && !(holder <: Tuple) && 1 <= name <= fieldcount(holder) && return site_kind(holder, fieldname(holder, name), scheduler)
    return site_kind(holder, name isa Symbol ? name : nothing, scheduler)
end

"""
Type of root of place in instance with IR `ir`: parameter type, type of constant global value (compiler uses it too),
or declared type of other global binding.
"""
root_type(ir::CC.IRCode, root::Root.Type)::Any = @match root begin
    Root.Parameter(position) => position <= length(ir.argtypes) ? CC.widenconst(ir.argtypes[position]) : Any
    Root.Global(binding) => global_type(binding)
    Root.Elsewhere() => Any
end

"""Type of constant global `binding` value, else declared type of binding; `Any` when undefined."""
function global_type(binding::GlobalRef)::Any
    isdefinedglobal(binding.mod, binding.name) || return Any
    return isconst(binding) ? typeof(getglobal(binding.mod, binding.name)) : Core.get_binding_type(binding.mod, binding.name)
end

"""
Type in `step` slot of object of `type`: `Union{}` when concrete `type` has no such field or position, as no value sits
there; `Any` when abstract type does not say. `Position` names tuple element, or field of struct that summary of struct
family (`Box{T} where T`) reads by index. `Element` of other than array or memory is `Any`: it names any element.
"""
function step_type(@nospecialize(type::Any), step::Step.Type)::Any
    type isa DataType || return Any
    concrete = isconcretetype(type)
    missing_slot = concrete ? Union{} : Any
    return @match step begin
        Step.Field(name) => hasfield(type, name) ? fieldtype(type, name) : missing_slot
        Step.Position(position) => (count = type <: Tuple || concrete ? Base.datatype_fieldcount(type) : 0; 1 <= position <= something(count, position) ? fieldtype(type, position) : missing_slot)
        Step.Element() => type <: Union{Array, GenericMemory} ? eltype(type) : Any
    end
end

"""
Kind of memory access to `place` in instance of `method` with IR `ir` (`engine.md`, Effect kinds): audited global when
`method` belongs to its package; else first special type or audited field along path, root first (JIT compile writes
below `Regex` field); else memory. Package method that writes `Dict` from `parsed_toml` writes memory below Base cache.
"""
function path_kind(ir::CC.IRCode, method::Method, place::Place.Type)::EffectKind.T
    root, steps = @match place begin
        Place.At(root, steps) => (root, steps)
        Place.Deep(root) => (root, Step.Type[])
    end
    global_kind = @match root begin
        Root.Global(binding) => Base.moduleroot(method.module) === Base.moduleroot(binding.mod) ? get(AUDITED_GLOBALS, binding, nothing) : nothing
        _ => nothing
    end
    isnothing(global_kind) || return global_kind
    type = root_type(ir, root)
    for step in steps
        found = special_kind(type)
        isnothing(found) || return found
        audited = @match step begin
            Step.Field(name) => audited_field(type, name)
            _ => nothing
        end
        isnothing(audited) || return audited
        type = step_type(type, step)
    end
    return something(special_kind(type), EffectKind.memory)
end

"""Whether instance with IR `ir` falls under `audit`: its argument types (after callee) fall in audit arguments."""
audit_fits(ir::CC.IRCode, audit::Audit)::Bool = audit.arguments === ANY_ARGUMENTS || Tuple{map(CC.widenconst, @view(ir.argtypes[2:end]))...} <: audit.arguments

"""
Kind of access with `kind` to `place` in instance of `method` with IR `ir`: audit of method (`Audit`) that covers it
gives its kind; else memory access takes kind of its path.
"""
function place_kind(ir::CC.IRCode, method::Method, place::Place.Type, kind::EffectKind.T)::EffectKind.T
    audit = get(AUDITED_METHODS, method, nothing)
    !isnothing(audit) && kind in audit.from && root_of(place) == audit.root && audit_fits(ir, audit) && return audit.kind
    return kind == EffectKind.memory ? path_kind(ir, method, place) : kind
end
