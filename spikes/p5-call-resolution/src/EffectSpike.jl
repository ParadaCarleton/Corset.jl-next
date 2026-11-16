"""
Spike S5: write summary per method instance on optimized typed IR.
Steensgaard points-to graph inside method; callee summaries at calls; Tarjan SCCs bottom-up.
"""
module EffectSpike

const CC = Core.Compiler

@enum Certainty::UInt8 NONE POSSIBLE DEFINITE

"""Join for writes and aliases: strongest evidence wins."""
lub(a::Certainty, b::Certainty)::Certainty = max(a, b)

"""Join across dispatch candidates: definite only when every candidate is definite."""
meet_candidates(certs::AbstractVector{Certainty})::Certainty =
    all(==(DEFINITE), certs) ? DEFINITE : any(>=(POSSIBLE), certs) ? POSSIBLE : NONE

"""Global binding or anonymous constant object."""
struct GlobalKey
    mod::Module
    name::Symbol
end

"""
Effect of method on one parameter. Depth counts content steps: 0 is parameter object, 1 its content.
Alias relations carry depths: `inside` (result at depth `d` of parameter), `contains` (parameter at depth `d` of
result), `overlap` (result depth `dr` meets parameter depth `dp`, both at least 1; iterate: element in result tuple).
"""
Base.@kwdef struct ParamEffect
    top::Certainty = NONE       # writes parameter object itself
    inner::Certainty = NONE     # writes object at depth 1
    deep::Certainty = NONE      # writes object at depth 2 or more (Dict write reaches storage, not stored values)
    same::Certainty = NONE      # result is parameter object
    inside::Certainty = NONE
    inside_depth::Int = 1
    contains::Certainty = NONE
    contains_depth::Int = 1
    overlap::Certainty = NONE
    overlap_depths::Tuple{Int, Int} = (1, 1)
end

"""Copy of `p` with fields in `changes` replaced."""
with(
    p::ParamEffect; top = p.top, inner = p.inner, deep = p.deep, same = p.same, inside = p.inside,
    inside_depth = p.inside_depth, contains = p.contains, contains_depth = p.contains_depth, overlap = p.overlap,
    overlap_depths = p.overlap_depths,
)::ParamEffect = ParamEffect(top, inner, deep, same, inside, inside_depth, contains, contains_depth, overlap, overlap_depths)

"""Strongest write certainty of `e` at any depth."""
written(e::ParamEffect)::Certainty = max(e.top, e.inner, e.deep)

const NO_EFFECT = ParamEffect()

"""Join alias relation `(cert, depth)` pairs: shallower depth over-merges at caller, staying sound; mixed depths are possible."""
function lub_alias(a::Certainty, da, b::Certainty, db)
    a == NONE && return b, db
    b == NONE && return a, da
    return da == db ? (lub(a, b), da) : (POSSIBLE, min(da, db))
end

function lub(a::ParamEffect, b::ParamEffect)::ParamEffect
    inside, inside_depth = lub_alias(a.inside, a.inside_depth, b.inside, b.inside_depth)
    contains, contains_depth = lub_alias(a.contains, a.contains_depth, b.contains, b.contains_depth)
    overlap, overlap_depths = lub_alias(a.overlap, a.overlap_depths, b.overlap, b.overlap_depths)
    return ParamEffect(
        lub(a.top, b.top), lub(a.inner, b.inner), lub(a.deep, b.deep), lub(a.same, b.same),
        inside, inside_depth, contains, contains_depth, overlap, overlap_depths
    )
end

"""
Calls of parameter callables: callee (parameter, depth) => operand parameter => shallowest depth reached.
Callback writes are deep and positionless, so shallowest depth per parameter covers every operand; depth 2 means 2 or more.
"""
const Calls = Dict{Tuple{Int, Int}, Dict{Int, Int}}

merge_calls(a::Calls, b::Calls)::Calls = mergewith((x, y) -> mergewith(min, x, y), a, b)

"""Callee type value: static parameter (`:sparam`, index) or parameter typed `Type{T}` (`:param`, index)."""
const TypeOrigin = Tuple{Symbol, Int}

"""Calls of type values: origin, then parameter per operand position (0: operand reaches no parameter)."""
const TypeCalls = Set{Tuple{TypeOrigin, Vector{Int}}}

"""Write summary per method instance."""
struct Summary
    params::Vector{ParamEffect}
    stores::Set{NTuple{4, Int}}         # (j, k, dj, dk): parameter k at depth dk meets parameter j at depth dj >= 1
    merges::Set{Tuple{Int, Int}}        # parameters j and k may alias after call
    globals::Dict{GlobalKey, Certainty} # globals written, own statements or callees
    direct::Set{GlobalKey}              # globals written by own statements
    result_globals::Dict{GlobalKey, Certainty}
    opaque::Bool                        # unknown callee, foreign call or untracked pointer
    fresh_result::Bool                  # result always allocated inside call
    assumed::Bool                       # some call resolved by Base contract, so "writes nothing" is assumption
    calls::Calls                        # calls of parameter callables; caller substitutes or demotes
    type_calls::TypeCalls               # calls of type values from static parameters; caller resolves or demotes
    joined::Vector{NTuple{3, Bool}}     # per parameter and depth bucket: possible only from candidate disagreement
    blames::Vector{String}              # per parameter: leaf cause of first possible write (diagnostic)
    gblames::Dict{GlobalKey, String}    # per global: same
end

Summary(params, stores, merges, globals, direct, result_globals, opaque, fresh, assumed) = Summary(
    params, stores, merges, globals, direct, result_globals, opaque, fresh, assumed, Calls(), TypeCalls(),
    fill((false, false, false), length(params)), fill("", length(params)), Dict{GlobalKey, String}()
)

bottom_summary(nparams::Int)::Summary = Summary(
    fill(NO_EFFECT, nparams), Set{NTuple{4, Int}}(), Set{Tuple{Int, Int}}(),
    Dict{GlobalKey, Certainty}(), Set{GlobalKey}(), Dict{GlobalKey, Certainty}(), false, true, false
)

# blame is diagnostic: fixpoint compares effects only
Base.:(==)(a::Summary, b::Summary)::Bool = all(getfield(a, f) == getfield(b, f) for f in fieldnames(Summary) if !(f in (:blames, :gblames)))

"""Bucket flags of `lub(a, b)`: possible bucket stays join-only when every possible input is join-only."""
function lub_joined(a::ParamEffect, b::ParamEffect, ja::NTuple{3, Bool}, jb::NTuple{3, Bool})::NTuple{3, Bool}
    flag(ca, cb, fa, fb) = max(ca, cb) == POSSIBLE && (ca != POSSIBLE || fa) && (cb != POSSIBLE || fb)
    return (flag(a.top, b.top, ja[1], jb[1]), flag(a.inner, b.inner, ja[2], jb[2]), flag(a.deep, b.deep, ja[3], jb[3]))
end

"""Merge dictionaries of certainties with `lub`."""
lub(a::Dict{GlobalKey, Certainty}, b::Dict{GlobalKey, Certainty})::Dict{GlobalKey, Certainty} = mergewith(lub, a, b)

function lub(a::Summary, b::Summary)::Summary
    length(a.params) == length(b.params) || error("summary arity mismatch")
    return Summary(
        lub.(a.params, b.params), a.stores ∪ b.stores, a.merges ∪ b.merges, lub(a.globals, b.globals),
        a.direct ∪ b.direct, lub(a.result_globals, b.result_globals), a.opaque || b.opaque, a.fresh_result && b.fresh_result,
        a.assumed || b.assumed, merge_calls(a.calls, b.calls), a.type_calls ∪ b.type_calls, lub_joined.(a.params, b.params, a.joined, b.joined), [isempty(x) ? y : x for (x, y) in zip(a.blames, b.blames)], merge(b.gblames, a.gblames)
    )
end

include("contracts.jl")
const CONTRACTS_ON = get(ENV, "S5_CONTRACTS", "1") == "1"

# ---------------------------------------------------------------- points-to graph

"""Union-find points-to graph; each class has at most one content class."""
mutable struct Graph
    parent::Vector{Int}
    content::Vector{Int}
    tainted::Vector{Bool}
    sources::Vector{Set{Any}}  # parameter indices, global keys, :fresh, :unknown
end

Graph() = Graph(Int[], Int[], Bool[], Set{Any}[])

function fresh!(g::Graph; tainted::Bool = false, sources::Set{Any} = Set{Any}())::Int
    push!(g.parent, length(g.parent) + 1); push!(g.content, 0); push!(g.tainted, tainted); push!(g.sources, sources)
    return length(g.parent)
end

"""Add source tag `src` to class of `l`; `:maybe` also marks every reachable class."""
function tag!(g::Graph, l::Int, src)::Nothing
    l == 0 && return
    targets = src === :maybe ? reach(g, l) : [find!(g, l)]
    foreach(r -> push!(g.sources[r], src), targets)
    return
end

function find!(g::Graph, l::Int)::Int
    while g.parent[l] != l
        g.parent[l] = g.parent[g.parent[l]]
        l = g.parent[l]
    end
    return l
end

"""Content class of `l`, created on demand."""
function content!(g::Graph, l::Int)::Int
    r = find!(g, l)
    # content of pure-fresh object is fresh until something is stored (store unifies sources)
    inherited = g.sources[r] == Set{Any}([:fresh]) ? Set{Any}([:fresh]) : setdiff(g.sources[r], (:fresh,))
    g.content[r] == 0 && (c = fresh!(g; tainted = g.tainted[r], sources = inherited); g.content[r] = c)
    return find!(g, g.content[r])
end

function unify!(g::Graph, a::Int, b::Int)::Int
    (a == 0 || b == 0) && return a + b
    ra, rb = find!(g, a), find!(g, b)
    ra == rb && return ra
    g.parent[rb] = ra
    g.tainted[ra] |= g.tainted[rb]
    union!(g.sources[ra], g.sources[rb])
    ca, cb = g.content[ra], g.content[rb]
    if ca != 0 && cb != 0
        unify!(g, ca, cb)
    elseif cb != 0
        g.content[ra] = cb
    end
    r = find!(g, ra)
    :maybe in g.sources[r] && foreach(c -> push!(g.sources[c], :maybe), reach(g, r))
    return r
end

"""Classes reachable from `l`, itself first."""
function reach(g::Graph, l::Int)::Vector{Int}
    seen = Int[]
    l == 0 && return seen
    r = find!(g, l)
    while r ∉ seen
        push!(seen, r)
        g.content[r] == 0 && break
        r = find!(g, g.content[r])
    end
    return seen
end

# ---------------------------------------------------------------- per-method state

const FRESH_ONLY = Set{Any}([:fresh])

const Base_ = Union{Nothing, Int, GlobalKey}  # must-derive source: parameter index or global

struct WriteSite
    loc::Int
    deep::Bool
    cert::Certainty
    base::Base_
    at::Int  # statement index, for tracing
    cause::String  # leaf cause when possible (diagnostic)
end

WriteSite(loc::Int, deep::Bool, cert::Certainty, base::Base_) = WriteSite(loc, deep, cert, base, CURRENT_STMT[], CAUSE[])
"""Call of unknown callable with classes of callee and operands; summary decides record or possible writes."""
struct Callback
    callee::Int
    ops::Vector{Int}
    cause::String
    at::Int
end

"""Call of type value with origin in this method, and operand classes in position order."""
struct TypeCallback
    origin::TypeOrigin
    ops::Vector{Int}  # operand classes
    args::Vector{Int}  # parameter index when operand is parameter itself, else 0: later merges leave it exact
    relaxed::Vector{Bool}  # callee record already relaxed position: writes stay possible
    cause::String
    at::Int
end

"""Index of parameter operand `x` is, else 0."""
arg_index(x)::Int = x isa Core.Argument ? x.n : 0

"""Operand standing for class `loc` of declared `type`; resolves type calls from callee records."""
struct ClassOperand
    loc::Int
    type::Any
end

"""Type call record resolved to callee type value; transfer applies its candidates after current statement."""
struct TypeCallSite
    callee::Type
    tt::Type
    ops::Vector{ClassOperand}
    cause::String
    capped::Bool  # some operand may be other object than its parameter: writes stay possible
end

demoted(w::WriteSite, cause::String)::WriteSite = WriteSite(w.loc, w.deep, POSSIBLE, w.base, w.at, w.cert == POSSIBLE ? w.cause : cause)

const CURRENT_STMT = Ref(0)
const CAUSE = Ref("")
const TRACE_UNKNOWN = Set{String}(split(get(ENV, "S5_TRACE_UNKNOWN", ""), ','; keepempty = false))
const TRACE = Ref(false)

"""Counters across one run."""
Base.@kwdef mutable struct Stats
    instances::Int = 0
    ir_failures::Int = 0
    unknown_calls::Int = 0
    resolved_dynamic::Int = 0
    foreign_unknown::Int = 0
    foreign_names::Dict{Symbol, Int} = Dict{Symbol, Int}()
    task_writes_skipped::Int = 0
    reasons::Dict{Symbol, Int} = Dict{Symbol, Int}()
    callees::Dict{String, Int} = Dict{String, Int}()
    lazy_init::Int = 0
    sccs::Int = 0
    max_scc::Int = 0
    iterations::Int = 0
    ir_seconds::Float64 = 0.0
    pkg_ir_seconds::Float64 = 0.0  # of which methods owned by package modules: inference stage infers them already
    pkg_instances::Int = 0
    effect_free::Int = 0            # instances compiler proves free of visible side effects
    effect_free_cleared::Int = 0    # of those, instances whose analysis found write
    effect_free_conflicts::Int = 0  # of those, instances whose analysis found definite write
    slow_sccs::Vector{Tuple{Float64, Int, Int, String}} = Tuple{Float64, Int, Int, String}[]  # seconds, size, rounds, member
end

mutable struct MethodState
    ir::CC.IRCode
    g::Graph
    locs::Dict{Any, Int}       # Argument / SSAValue / GlobalKey -> class
    bases::Dict{Any, Base_}
    writes::Vector{WriteSite}
    direct::Set{GlobalKey}
    opaque::Bool
    returns::Vector{Any}
    assumed::Bool
    name::String
    optimistic::Vector{Pair{Core.SSAValue, Vector{Any}}}  # phi base assumed from forward operands; back-edge operands to check
    pessimistic::Set{Int}                                # phis whose back-edge operands disagreed
    callbacks::Vector{Callback}
    used::BitSet  # SSA values some statement reads
    type_callbacks::Vector{TypeCallback}
    pending::Vector{TypeCallSite}
    mi::Core.MethodInstance
end

"""SSA values some statement reads as value; branch conditions only steer control, so they alias nothing."""
function used_values(ir::CC.IRCode)::BitSet
    used = BitSet()
    for stmt in ir.stmts.stmt, ur in CC.userefs(stmt)
        stmt isa Core.GotoIfNot && continue
        v = ur[]
        v isa Core.SSAValue && push!(used, v.id)
    end
    return used
end

"""Whether values of type `t` can hold references; bits values other than pointers never alias."""
function tracked(t)::Bool
    t = CC.widenconst(t)
    t <: Ptr && return true
    t === Union{} && return false
    (isconcretetype(t) && isbitstype(t)) && return false
    t <: Union{Symbol, Type, Module, Core.Builtin} && return false
    return true
end

"""Element `index` of tuple operand `tuple`, splatted into call by `_apply_iterate`; index 0 is any element."""
struct Element
    tuple::Any
    index::Int
end

"""IR type of operand `x`; `Any` for operands IR does not type (nested expressions)."""
argtype(x, ir::CC.IRCode)::Any =
    x isa Expr ? Any : x isa ClassOperand ? x.type : x isa Element ? element_type(CC.widenconst(argtype(x.tuple, ir)), x.index) : CC.argextype(x, ir)

"""Whether `t` is tuple type of known length; element types may be abstract (`Tuple{Vector{<:Integer}, Any}`)."""
fixed_length(t)::Bool = t isa DataType && t <: Tuple && (isempty(t.parameters) || !Base.isvarargtype(last(t.parameters)))

"""Splatted operand types whose iteration yields stored elements and writes nothing."""
const SPLATTED = Union{Tuple, NamedTuple, Array}

"""Type of element `index` of tuple, named tuple or array type `t`; index 0 is any element."""
function element_type(t::Type, index::Int)::Type
    index > 0 && return fieldtype(t, index)
    t <: AbstractArray && return eltype(t)
    t <: NamedTuple && return (u = Base.unwrap_unionall(t); u isa DataType && length(u.parameters) == 2 && u.parameters[2] isa Type ? element_type(u.parameters[2], 0) : Any)
    t = Base.unwrap_unionall(t)
    t isa DataType && t <: Tuple || return Any
    bound(p) = (u = Base.unwrapva(p); u isa TypeVar ? u.ub : u isa Type ? u : Any)
    return Union{Any[bound(p) for p in t.parameters]...}
end

typeof_operand(st::MethodState, x)::Any = CC.widenconst(argtype(x, st.ir))

"""Reverse map from constant mutable object to its binding, filled once per run."""
const CONST_NAMES = IdDict{Any, GlobalKey}()

function index_constants!()::Nothing
    isempty(CONST_NAMES) || return
    seen = Set{Module}()
    todo = collect(Module, Base.loaded_modules_array())
    while !isempty(todo)
        m = pop!(todo)
        m in seen && continue
        push!(seen, m)
        for n in names(m; all = true, imported = false)
            (isdefined(m, n) && isconst(m, n)) || continue
            v = try
                getglobal(m, n)
            catch
                continue
            end
            v isa Module ? (parentmodule(v) === m && push!(todo, v)) :
                ismutable(v) && !(v isa Type) && !haskey(CONST_NAMES, v) && (CONST_NAMES[v] = GlobalKey(m, n))
        end
    end
    return
end

const_key(v)::GlobalKey = get(CONST_NAMES, v, GlobalKey(Core, Symbol("<anonymous ", typeof(v), ">")))

"""Class of operand `x`; zero when `x` cannot alias."""
function loc!(st::MethodState, x)::Int
    x isa ClassOperand && return x.loc
    x isa Element && return tracked(argtype(x, st.ir)) ? content_of!(st, x.tuple) : 0
    if x isa Core.Argument || x isa Core.SSAValue
        tracked(argtype(x, st.ir)) || return 0
        return get!(st.locs, x) do
            x isa Core.Argument ? fresh!(st.g; sources = Set{Any}([x.n])) : fresh!(st.g)
        end
    elseif x isa GlobalRef
        if isconst(x.mod, x.name) && isdefined(x.mod, x.name)
            v = getglobal(x.mod, x.name)
            (ismutable(v) && !(v isa Union{Type, Module})) || return 0
        end
        return global_loc!(st, GlobalKey(x.mod, x.name))
    elseif x isa QuoteNode
        return loc!(st, x.value)
    elseif ismutable(x) && !(x isa Union{Type, Module, Symbol, String, Core.Builtin})
        return global_loc!(st, const_key(x))
    end
    return 0
end

global_loc!(st::MethodState, k::GlobalKey)::Int = get!(() -> fresh!(st.g; sources = Set{Any}([k])), st.locs, k)

function base_of(st::MethodState, x)::Base_
    x isa ClassOperand && return nothing
    x isa Element && return nothing
    x isa Core.Argument && return x.n
    x isa GlobalRef && return GlobalKey(x.mod, x.name)
    x isa Core.SSAValue && return get(st.bases, x, nothing)
    x isa QuoteNode && return base_of(st, x.value)
    ismutable(x) && !(x isa Union{Type, Module, Symbol, String}) && return const_key(x)
    return nothing
end

function record!(st::MethodState, x, loc::Int, deep::Bool, cert::Certainty)::Nothing
    (loc == 0 || cert == NONE) && return
    if x !== nothing && typeof_operand(st, x) <: Union{Task, Regex}
        return  # task-local state (RNG, task storage); lazy Regex compile cache
    end
    # object allocated here and not yet reachable from parameter or global: invisible to caller;
    # a later store that exposes it is itself a recorded write
    all(r -> st.g.sources[r] == FRESH_ONLY, deep ? reach(st.g, loc) : [find!(st.g, loc)]) && return
    b = base_of(st, x)
    b isa GlobalKey && cert == DEFINITE && push!(st.direct, b)
    push!(st.writes, WriteSite(loc, deep, cert, b))
    return
end

# ---------------------------------------------------------------- builtins

const FIELD_WRITES = (setfield!, Core.setproperty!, Core.setfieldonce!, Core.modifyfield!, Core.swapfield!, Core.replacefield!)
const MEMORY_WRITES = (Core.memoryrefset!, Core.memoryrefsetonce!, Core.memoryrefmodify!, Core.memoryrefswap!, Core.memoryrefreplace!)
const GLOBAL_WRITES = (setglobal!, Core.setglobalonce!, Core.swapglobal!, Core.modifyglobal!, Core.replaceglobal!)
const POINTER_WRITES = (
    Core.Intrinsics.pointerset, Core.Intrinsics.atomic_pointerset, Core.Intrinsics.atomic_pointerswap,
    Core.Intrinsics.atomic_pointermodify, Core.Intrinsics.atomic_pointerreplace,
)
const DYNAMIC_BUILTINS = (
    Core._apply_iterate, Core.invoke, Core.invoke_in_world, Core.invokelatest, Core._call_in_world,
    Core._call_in_world_total, Core._call_latest, Core.finalizer,
)

# C functions with known behavior: written argument positions, and result origin
# (`:fresh` allocation, `:bits` untracked, or argument positions it points into).
const FOREIGN = Dict{Symbol, Tuple{Vector{Int}, Union{Symbol, Vector{Int}}}}(
    :memmove => ([1], [1]), :memcpy => ([1], [1]), :memset => ([1], [1]),
    :jl_genericmemory_copyto => ([1], :bits),
    :memcmp => (Int[], :bits), :memchr => (Int[], [1]), :strlen => (Int[], :bits), :jl_object_id => (Int[], :bits),
    :memhash_seed => (Int[], :bits), :jl_alloc_genericmemory => (Int[], :fresh), :jl_alloc_string => (Int[], :fresh),
    :jl_genericmemory_to_string => (Int[], :fresh), :jl_string_to_genericmemory => (Int[], :fresh),
    :jl_pchar_to_string => (Int[], :fresh), :jl_get_current_task => (Int[], :fresh), :jl_string_ptr => (Int[], [1]),
    :jl_genericmemory_owner => (Int[], [1]), :jl_value_ptr => (Int[], [1]), :jl_ptr_to_array_1d => (Int[], [2]),
    :jl_array_ptr => (Int[], [1]), :jl_genericmemory_slice => (Int[], [1]),
    :jl_genericmemory_copy_slice => (Int[], :fresh), :jl_genericmemory_copy => (Int[], :fresh),
    :jl_eqtable_put => ([1], [1]), :jl_eqtable_pop => ([1], :bits), :jl_eqtable_get => (Int[], [1]),
    :jl_idtable_rehash => (Int[], :fresh), :jl_cstr_to_string => (Int[], :fresh), :malloc => (Int[], :fresh),
)

# Runtime, scheduler, GC and libuv calls: write task, thread or OS state only (task and IO exemptions).
for name in (
        :jl_rethrow, :jl_sigatomic_begin, :jl_sigatomic_end, :jl_cpu_suspend, :jl_cpu_wake, :jl_gc_safepoint,
        :jl_threadpoolid, :jl_threadid, :jl_get_next_task, :jl_set_next_task, :jl_process_events, :jl_iolock_begin,
        :jl_iolock_end, :jl_set_task_tid, :jl_get_task_tid, :jl_gc_is_in_finalizer, :jl_hrtime, :jl_get_ptls_rng,
        :jl_set_ptls_rng, :jl_gc_enable_finalizers_internal, :jl_gc_disable_finalizers_internal,
        :jl_gc_run_pending_finalizers, :jl_wakeup_thread, :jl_wakeup_threadpool, :jl_get_task_threadpoolid,
        :jl_task_get_next, :jl_switch, :jl_new_task, :jl_safe_printf, :uv_err_name, :uv_strerror, :utf8proc_charwidth,
        :uv_handle_set_data, :uv_req_set_data, :uv_req_get_data, :jl_uv_write, :free, :jl_set_precompile_field_replace,
    )
    FOREIGN[name] = (Int[], :bits)
end

# Runtime queries: read arguments, return immutable values (symbols, types, booleans, indices).
for name in (
        :jl_symbol_n, :jl_symbol, :jl_type_intersection, :jl_has_free_typevars, :jl_has_typevar,
        :jl_argument_datatype, :jl_idset_peek_bp, :jl_types_equal, :jl_type_morespecific,
    )
    FOREIGN[name] = (Int[], :bits)
end

const GMP_READ = r"(cmp|sgn|sizeinbase|_size$|fits_|tstbit|popcount|hamdist|scan[01]|divisible|congruent|perfect_|probab_prime|equal|_p$|get_si|get_ui|get_d$|get_flt|get_prec|get_exp|signbit|min_prec|jacobi|legendre|kronecker)"
const GMP_OUTPUTS = Dict(
    "get_str" => [1, 2], "export" => [1, 2], "frexp" => [1, 2], "qr" => [1, 2], "sqrtrem" => [1, 2], "rootrem" => [1, 2],
    "gcdext" => [1, 2, 3], "sin_cos" => [1, 2], "sinh_cosh" => [1, 2], "modf" => [1, 2], "remquo" => [1, 2], "lgamma" => [1, 2],
)

"""
GMP and MPFR C function `name` (outputs first by library convention): written positions and `:bits` result.
Read-only names write nothing; listed multi-output names write their leading outputs; else first argument.
"""
function gmp_mpfr(name::Symbol)::Union{Nothing, Tuple{Vector{Int}, Symbol}}
    s = string(name)
    startswith(s, "__gmp") || startswith(s, "mpfr_") || return nothing
    occursin(GMP_READ, s) && !occursin("get_str", s) && return (Int[], :bits)
    k = findfirst(key -> endswith(s, key), collect(keys(GMP_OUTPUTS)))
    return (k === nothing ? [1] : GMP_OUTPUTS[collect(keys(GMP_OUTPUTS))[k]], :bits)
end

foreign_name(x)::Union{Nothing, Symbol} =
    x isa QuoteNode ? foreign_name(x.value) : x isa Symbol ? x :
    (x isa Expr && x.head === :tuple) ? foreign_name(first(x.args)) : x isa Tuple ? foreign_name(first(x)) : nothing

const_value(st::MethodState, x) = (t = argtype(x, st.ir); t isa Core.Const ? t.val : nothing)

# ---------------------------------------------------------------- statements

"""Context passed to statement transfer: callee summary lookup and dynamic resolution."""
struct Ctx
    summary::Function   # MethodInstance -> Union{Nothing, Summary}
    stats::Stats
end

function transfer!(st::MethodState, ctx::Ctx, i::Int, stmt)::Nothing
    res = Core.SSAValue(i)
    if stmt isa Core.PhiNode || stmt isa Core.PhiCNode
        vals = [stmt.values[k] for k in eachindex(stmt.values) if isassigned(stmt.values, k)]
        foreach(v -> unify!(st.g, loc!(st, res), loc!(st, v)), vals)
        # back-edge operands are not yet transferred: assume their base, check after pass
        later = Any[v for v in vals if v isa Core.SSAValue && v.id >= res.id]
        bs = unique(base_of.((st,), res.id in st.pessimistic ? vals : setdiff(vals, later)))
        length(bs) == 1 && only(bs) !== nothing && (st.bases[res] = only(bs); isempty(later) || push!(st.optimistic, res => later))
    elseif stmt isa Core.PiNode || stmt isa Core.UpsilonNode
        isdefined(stmt, :val) || return
        unify!(st.g, loc!(st, res), loc!(st, stmt.val)); st.bases[res] = base_of(st, stmt.val)
    elseif stmt isa GlobalRef
        unify!(st.g, loc!(st, res), loc!(st, stmt)); st.bases[res] = base_of(st, stmt)
    elseif stmt isa Core.ReturnNode
        isdefined(stmt, :val) && push!(st.returns, stmt.val)
    elseif stmt isa Expr
        transfer_expr!(st, ctx, res, stmt)
    end
    return
end

function transfer_expr!(st::MethodState, ctx::Ctx, res::Core.SSAValue, e::Expr)::Nothing
    if e.head === :new || e.head === :splatnew
        # content first: fields hold exactly stored operands, not fresh objects; storage fields are object itself
        T = CC.widenconst(argtype(e.args[1], st.ir))
        T = T isa DataType && T <: Type && length(T.parameters) == 1 && T.parameters[1] isa Type ? T.parameters[1] : Any
        c = content_of!(st, res)
        for (i, x) in enumerate(e.args[2:end])
            s = e.head === :new ? storage_field(T, i) : has_storage(T) === true ? nothing : false
            s === false || unify!(st.g, loc!(st, res), loc!(st, x))
            s === true || unify!(st.g, c, loc!(st, x))
        end
        tag!(st.g, loc!(st, res), :fresh)
    elseif e.head === :invoke
        ci = e.args[1]
        mi = ci isa Core.CodeInstance ? CC.get_ci_mi(ci) : ci
        s = mi isa Core.MethodInstance ? ctx.summary(mi) : nothing
        s === nothing ? unknown_call!(st, ctx, res, e.args[2:end], :invoke_nosummary) : apply_summary!(st, res, e.args[2:end], mi.def, s, mi.sparam_vals)
    elseif e.head === :call
        transfer_call!(st, ctx, res, e)
    elseif e.head === :foreigncall
        transfer_foreign!(st, ctx, res, e)
    elseif e.head === :new_opaque_closure || e.head === :cfunction
        unknown_call!(st, ctx, res, e.args, :opaque_closure)
    end
    return
end

content_of!(st::MethodState, x)::Int = (l = loc!(st, x); l == 0 ? 0 : content!(st.g, l))

const STORAGE = Union{Core.GenericMemory, Core.GenericMemoryRef}

"""
Declared field types of `T`'s generic struct (type parameters free). Storage classification reads them, so every
instance of one struct classifies field alike (`Foo{T}` field `x::T` is never storage, even as `Foo{Memory{Int}}`).
"""
function declared_fieldtypes(@nospecialize(T))::Union{Nothing, Vector{Any}}
    u = Base.unwrap_unionall(T)
    u isa DataType || return nothing
    (isabstracttype(u) || u === Any) && return nothing
    w = Base.unwrap_unionall(u.name.wrapper)
    # tuple-like types have no definite field count
    Base.isvatuple(w) || w.name === NamedTuple.body.body.name && return nothing
    return try
        collect(Any, fieldtypes(w))
    catch
        nothing
    end
end

is_storage(@nospecialize(ft))::Bool = ft isa Type && ft <: STORAGE

"""Whether mutable struct type `T` has `Memory` or `MemoryRef` field; `nothing` for abstract or union `T`."""
function has_storage(@nospecialize(T))::Union{Nothing, Bool}
    u = Base.unwrap_unionall(T)
    u isa DataType && !isabstracttype(u) && u !== Any && !ismutabletype(u) && return false
    fts = declared_fieldtypes(T)
    fts === nothing && return nothing
    return any(is_storage, fts)
end

"""
Whether field `f` of `T` is storage object owns (`Memory` or `MemoryRef` field of mutable struct): storage shares
owner's class, so elements sit one level below owner, as contracts put them. `nothing` when `f` is unknown.
"""
function storage_field(@nospecialize(T), f)::Union{Nothing, Bool}
    has = has_storage(T)
    has === true || return false  # gap: untyped owner reads storage field as content
    fts = declared_fieldtypes(T)::Vector{Any}
    u = Base.unwrap_unionall(Base.unwrap_unionall(T).name.wrapper)
    i = f isa Int ? f : f isa Symbol ? Base.fieldindex(u, f, false) : 0
    1 <= i <= length(fts) || return nothing
    return is_storage(fts[i])
end

"""Classes field `f` of `x` lives in: owner itself (storage field), its content, or both when field is unknown."""
function field_classes!(st::MethodState, x, f)::Vector{Int}
    s = storage_field(typeof_operand(st, x), f === nothing ? nothing : const_value(st, f))
    s === true && return [loc!(st, x)]
    s === false && return [content_of!(st, x)]
    return [loc!(st, x), content_of!(st, x)]
end

function transfer_call!(st::MethodState, ctx::Ctx, res::Core.SSAValue, e::Expr)::Nothing
    f = CC.singleton_type(argtype(e.args[1], st.ir))
    args = e.args[2:end]
    if f === getfield || f === Core.getproperty || f === Core.memoryrefget
        isempty(args) && return
        # pointer field points into object's own storage; other fields load referenced objects.
        # memory reference is its memory (`memoryrefnew` unifies them), so `ref.mem` is same class
        own = f !== Core.memoryrefget && (typeof_operand(st, res) <: Ptr || typeof_operand(st, args[1]) <: Core.GenericMemoryRef)
        targets = own ? [loc!(st, args[1])] : f === Core.memoryrefget ? [content_of!(st, args[1])] : field_classes!(st, args[1], get(args, 2, nothing))
        foreach(c -> unify!(st.g, loc!(st, res), c), targets); st.bases[res] = base_of(st, args[1])
    elseif f === Core.memoryrefnew || f === Core.ifelse || f === Core.compilerbarrier || f === Core.typeassert
        # result is operand: typeassert(x, T) returns x
        srcs = f === Core.ifelse ? args[2:3] : f === Core.compilerbarrier ? args[2:2] : args[1:1]
        foreach(x -> unify!(st.g, loc!(st, res), loc!(st, x)), srcs)
        bs = unique(base_of.((st,), srcs)); length(bs) == 1 && (st.bases[res] = only(bs))
    elseif f in FIELD_WRITES || f in MEMORY_WRITES
        # write-once lazy init (LazyString, once-caches) is invisible memoization
        lazy = f === Core.setfieldonce! || (f === Core.replacefield! && length(args) >= 3 && (t3 = argtype(args[3], st.ir); t3 isa Core.Const && t3.val === nothing))
        lazy ? (ctx.stats.lazy_init += 1) : record!(st, args[1], loc!(st, args[1]), false, DEFINITE)
        targets = f in MEMORY_WRITES ? [content_of!(st, args[1])] : field_classes!(st, args[1], get(args, 2, nothing))
        foreach(x -> foreach(c -> unify!(st.g, c, loc!(st, x)), targets), args[2:end])
        # setfield! returns stored value; swap returns old content; modify and replace return tuple holding both
        f === setfield! && length(args) >= 3 && unify!(st.g, loc!(st, res), loc!(st, args[3]))
        f in (Core.swapfield!, Core.memoryrefswap!) && foreach(c -> unify!(st.g, loc!(st, res), c), targets)
        f in (Core.modifyfield!, Core.replacefield!, Core.memoryrefmodify!, Core.memoryrefreplace!) &&
            foreach(c -> unify!(st.g, content_of!(st, res), c), targets)
    elseif f === tuple || f === Core.svec
        c = content_of!(st, res)
        foreach(x -> unify!(st.g, c, loc!(st, x)), args)
        tag!(st.g, loc!(st, res), :fresh)
    elseif f === Core.memorynew
        tag!(st.g, loc!(st, res), :fresh)
    elseif f === getglobal || f in GLOBAL_WRITES
        m, n = const_value(st, args[1]), const_value(st, get(args, 2, nothing))
        if m isa Module && n isa Symbol
            k = GlobalKey(m, n); l = global_loc!(st, k)
            if f === getglobal
                unify!(st.g, loc!(st, res), l); st.bases[res] = k
            else
                push!(st.direct, k); push!(st.writes, WriteSite(l, false, DEFINITE, k))
                foreach(x -> unify!(st.g, content!(st.g, l), loc!(st, x)), args[3:end])
            end
        elseif f !== getglobal
            st.opaque = true
        end
    elseif f in POINTER_WRITES
        # store happens; pointer class sources decide which object it hits
        record!(st, args[1], loc!(st, args[1]), false, DEFINITE)
    elseif f isa Core.IntrinsicFunction
        transfer_intrinsic!(st, res, args)
    elseif f isa Core.Builtin && !(f in DYNAMIC_BUILTINS)
        return  # remaining builtins read only: typeof, ===, isa, nfields, throw, ...
    elseif f === Core._apply_iterate
        apply_iterate!(st, ctx, res, e.args)
    elseif f === Core.invoke && (info = st.ir.stmts.info[res.id]) isa CC.InvokeCallInfo
        # invoke(f, T, args...): call f on args at method T selects
        resolved_call!(st, ctx, res, Any[e.args[2]; e.args[4:end]], [info.match])
    elseif f === Core.invoke && (cands = invoke_candidates(st.ir, e.args)) !== nothing
        dynamic_call!(st, ctx, res, Any[e.args[2]; e.args[4:end]], CC.singleton_type(argtype(e.args[2], st.ir)), cands)
    elseif CONTRACTS_ON && (f === Base.getproperty || f === Base.setproperty!) && default_property(st, e.args)
        # Base default method with constant field: field load or store; `convert` to field type is contract
        st.assumed = true
        transfer_call!(st, ctx, res, Expr(:call, f === Base.getproperty ? Core.getfield : Core.setfield!, e.args[2:end]...))
    else
        matches = matched(st.ir.stmts.info[res.id])
        matches === nothing ? dynamic_call!(st, ctx, res, e.args, f, stmt_candidates(st.ir, res.id, e.args)) : resolved_call!(st, ctx, res, e.args, matches)
    end
    return
end

const DEFAULT_PROPERTY = (which(Base.getproperty, (Any, Symbol)), which(Base.setproperty!, (Any, Symbol, Any)))

"""Whether property call `args` (callee first) has constant field and dispatches to Base default method only."""
function default_property(st::MethodState, args)::Bool
    length(args) in (3, 4) || return false
    const_value(st, args[3]) isa Symbol || return false
    tt = Tuple{(typeof_operand(st, x) for x in args)...}
    ms = try
        Base._methods_by_ftype(tt, 2, Base.get_world_counter())
    catch
        nothing
    end
    return ms isa Vector && length(ms) == 1 && only(ms).method in DEFAULT_PROPERTY && only(ms).fully_covers
end

"""
`_apply_iterate(iterate, f, tuples...)` that inference resolved: call `f` with tuple elements as operands.
Splatted operand other than fixed-length tuple, or other iterator function: unknown call.
"""
function apply_iterate!(st::MethodState, ctx::Ctx, res::Union{Nothing, Core.SSAValue}, args)::Nothing
    info = st.ir.stmts.info[res.id]
    matches = info isa Union{CC.ApplyCallInfo, CC.UnionSplitApplyCallInfo} ? matched(info) : nothing
    fixed(x) = fixed_length(typeof_operand(st, x))
    shaped = CC.singleton_type(argtype(args[2], st.ir)) === iterate && all(fixed, args[4:end])
    f = CC.singleton_type(argtype(args[3], st.ir))
    contract = contract_of(f, nothing)
    if CC.singleton_type(argtype(args[2], st.ir)) === iterate && (f === tuple || f === Core.svec) &&
            all(x -> typeof_operand(st, x) <: SPLATTED, args[4:end])
        # fresh tuple holding splatted elements, any shape
        c = content_of!(st, res)
        foreach(x -> unify!(st.g, c, content_of!(st, x)), args[4:end])
        return tag!(st.g, loc!(st, res), :fresh)
    end
    if shaped && f isa Core.Builtin && !(f in DYNAMIC_BUILTINS)
        # builtin on known elements: same transfer as direct call
        return transfer_call!(st, ctx, res, Expr(:call, QuoteNode(f), (Element(x, k) for x in args[4:end] for k in 1:fieldcount(typeof_operand(st, x)))...))
    end
    if shaped
        ops = Any[args[3]]
        foreach(x -> append!(ops, Element(x, k) for k in 1:fieldcount(typeof_operand(st, x))), args[4:end])
        matches === nothing || return resolved_call!(st, ctx, res, ops, matches)
        return dynamic_call!(st, ctx, res, ops, f)
    end
    splat_call!(st, ctx, res, args, matches) && return
    if contract === PURE
        # pure contract ignores operand positions
        return apply_contract!(st, ctx, res, Any[args[3]], contract)
    end
    return unknown_call!(st, ctx, res, args, matches === nothing ? :apply_unresolved : :apply_shape)
end

"""
Splat with one operand of unknown length (`f(a, rest...)`): join candidates of `f(a, Vararg{eltype(rest)})`.
Remaining parameters bind any element of `rest`; writes through it are possible (it may be empty).
Return `false` when shape or callee is unsupported.
"""
function splat_call!(st::MethodState, ctx::Ctx, res::Union{Nothing, Core.SSAValue}, args, matches)::Bool
    shape = splat_shape(st.ir, args)
    (shape === nothing || shape.rest === nothing) && return false
    f, prefix, tt = shape.f, shape.prefix, shape.tt
    any_element = Element(shape.rest, 0)
    # inference matches are exact and discovered; else loaded methods at declared signatures
    cands = matches === nothing ? candidate_instances(tt) : [(m.method, CC.specialize_method(m)) for m in matches]
    if cands === nothing
        contract = contract_of(f, nothing)
        contract === nothing && return false
        n0 = length(st.writes)
        apply_contract!(st, ctx, res, Any[args[3]; prefix; any_element], contract)
        demote_elements!(st, n0, any_element, "splat $(f) @ $(st.name)")
        return true
    end
    st.assumed = true
    sums = Tuple{Method, Summary, Core.SimpleVector}[]
    for (m, mi) in cands
        s = ctx.summary(mi)
        s === nothing && return false
        push!(sums, (m, s, mi.sparam_vals))
    end
    ctx.stats.reasons[:splat] = get(ctx.stats.reasons, :splat, 0) + 1
    tag!(st.g, loc!(st, res), :maybe)
    n0 = length(st.writes)
    opsof(m) = Any[args[3]; prefix; fill(any_element, max(Int(m.nargs) - 1 - length(prefix), 1))]
    join_apply!(st, res, [(opsof(m), m, s, sv) for (m, s, sv) in sums], "join $(something(f, "callee")) @ $(st.name)")
    demote_elements!(st, n0, any_element, "splat $(something(f, "callee")) @ $(st.name)")
    return true
end

"""Demote definite writes after index `n0` that reach elements of splatted operand: it may be empty."""
function demote_elements!(st::MethodState, n0::Int, any_element::Element, cause::String)::Nothing
    el = loc!(st, any_element)
    el == 0 && return
    for i in (n0 + 1):length(st.writes)
        w = st.writes[i]
        w.cert == DEFINITE && find!(st.g, w.loc) in reach(st.g, el) && (st.writes[i] = demoted(w, cause))
    end
    return
end

"""
Call type of `invoke(f, T, args...)` (`args` as statement holds them) whose `T` inference left open: `f` with upper
bound of `T`. Every method some `T` selects intersects it, so candidates cover call. `nothing` when bound is unclear.
"""
function invoke_type(ir::CC.IRCode, args)::Union{Nothing, Type}
    length(args) >= 3 || return nothing
    tT = Base.unwrap_unionall(CC.widenconst(argtype(args[3], ir)))
    (tT isa DataType && tT <: Type && !isempty(tT.parameters)) || return nothing
    ub = tT.parameters[1]
    ub isa TypeVar && (ub = ub.ub)
    ub = Base.unwrap_unionall(ub)
    (ub isa DataType && ub <: Tuple) || return nothing
    return Tuple{CC.widenconst(argtype(args[2], ir)), ub.parameters...}
end

"""
Exact elements of `T` in `invoke(f, T, args...)` built by `apply_type(Tuple, elems...)`, as Base fallbacks do:
constant element is exact type, other element `nothing`. All `nothing` when `T` has other origin.
"""
function invoke_exact(ir::CC.IRCode, args, n::Int)::Vector{Union{Nothing, Type}}
    open = Vector{Union{Nothing, Type}}(nothing, n)
    x = args[3]
    x isa Core.SSAValue || return open
    stmt = ir.stmts.stmt[x.id]
    (stmt isa Expr && stmt.head === :call && length(stmt.args) == n + 2) || return open
    CC.singleton_type(argtype(stmt.args[1], ir)) === Core.apply_type && CC.singleton_type(argtype(stmt.args[2], ir)) === Tuple || return open
    exact(e) = (t = CC.widenconst(argtype(e, ir)); t isa DataType && t <: Type && !isempty(t.parameters) && t.parameters[1] isa Type ? t.parameters[1] : nothing)
    return Union{Nothing, Type}[exact(e) for e in stmt.args[3:end]]
end

"""Whether `invoke` with type tuple holding `exact` elements can select `m`: `T <: m.sig` needs each slot to accept them."""
function invoke_selects(m::Method, exact::Vector{Union{Nothing, Type}})::Bool
    body = Base.unwrap_unionall(m.sig)
    params = collect(body.parameters)
    (any(Base.isvarargtype, params) || length(params) != length(exact) + 1) && return true
    probe = Tuple{params[1], (something(e, p) for (e, p) in zip(exact, params[2:end]))...}
    return Base.rewrap_unionall(probe, m.sig) <: m.sig
end

"""Methods open `invoke(f, T, args...)` may select (`args` as statement holds them); `nothing` when unclear or many."""
function invoke_candidates(ir::CC.IRCode, args)::Union{Nothing, Vector{Tuple{Method, Core.MethodInstance}}}
    tt = invoke_type(ir, args)
    tt === nothing && return nothing
    # vararg bound: no exact slots, every intersecting method stays
    exact = fixed_length(tt) ? invoke_exact(ir, args, fieldcount(tt) - 1) : Union{Nothing, Type}[]
    ms = try
        Base._methods_by_ftype(tt, PACKAGE_CAP, Base.get_world_counter())
    catch
        nothing
    end
    ms isa Vector || return nothing
    filter!(m -> invoke_selects(m.method, exact), ms)
    (isempty(ms) || length(ms) > MAX_CANDIDATES) && return nothing
    return [(m.method, Base.isdispatchtuple(m.spec_types) ? CC.specialize_method(m) : declared_instance(m.method)) for m in ms]
end

"""
Shape of `_apply_iterate(iterate, f, splats...)` (`args` as statement holds them, builtin first): `f`, operands from fixed-length tuples
(`prefix`), last splat of unknown length (`rest`, else `nothing`), and call type for candidate lookup.
Transfer and callee discovery both use it, so discovered candidates match resolved ones. `nothing` when unsupported.
"""
function splat_shape(ir::CC.IRCode, args)
    CC.singleton_type(argtype(args[2], ir)) === iterate || return nothing
    optype(x) = CC.widenconst(argtype(x, ir))
    fixed(x) = fixed_length(optype(x))
    splats = args[4:end]
    k = findfirst(!fixed, splats)
    prefix = Any[Element(x, i) for x in splats[1:(something(k, length(splats) + 1) - 1)] for i in 1:fieldcount(optype(x))]
    f = CC.singleton_type(argtype(args[3], ir))
    k === nothing && return (f, prefix, rest = nothing, tt = Tuple{optype(args[3]), map(optype, prefix)...})
    k == length(splats) || return nothing
    rest = splats[k]
    optype(rest) <: SPLATTED || return nothing
    # callee by type: singleton function, or typed value such as constructor built by `apply_type`
    return (f, prefix, rest, tt = Tuple{optype(args[3]), map(optype, prefix)..., Vararg{optype(Element(rest, 0))}})
end

"""
Apply several candidate summaries to one call; each entry holds operands, method and summary.
Write stays definite when every candidate writes same class definitely; else demoted with `cause`.
"""
function join_apply!(st::MethodState, res::Union{Nothing, Core.SSAValue}, cands::Vector, cause::String)::Nothing
    if length(cands) == 1
        ops, m, s, sv = only(cands)
        return apply_summary!(st, res, ops, m, s, sv)
    end
    tag!(st.g, loc!(st, res), :maybe)
    ranges = UnitRange{Int}[]
    for (ops, m, s, sv) in cands
        n0 = length(st.writes)
        apply_summary!(st, res, ops, m, s, sv)
        push!(ranges, (n0 + 1):length(st.writes))
    end
    key(w::WriteSite) = (find!(st.g, w.loc), w.deep, w.base)
    agreed = [Set(key(st.writes[i]) for i in r if st.writes[i].cert == DEFINITE) for r in ranges]
    common = reduce(intersect, agreed)
    for i in first(first(ranges)):last(last(ranges))
        w = st.writes[i]
        w.cert == DEFINITE && !(key(w) in common) && (st.writes[i] = demoted(w, cause))
    end
    return
end

"""Apply Base `contract` to call with `ops`; verdict relies on contract."""
function apply_contract!(st::MethodState, ctx::Ctx, res::Union{Nothing, Core.SSAValue}, ops, contract::Contract)::Nothing
    ctx.stats.reasons[:contract] = get(ctx.stats.reasons, :contract, 0) + 1
    return apply_summary!(st, res, ops, nothing, contract_summary(contract, length(ops)), Core.svec())
end

"""Call inference resolved: apply summary of each matched instance; several matches demote definite writes."""
function resolved_call!(st::MethodState, ctx::Ctx, res::Union{Nothing, Core.SSAValue}, ops, matches::Vector{Core.MethodMatch})::Nothing
    sums = Tuple{Method, Summary, Core.SimpleVector}[]
    for m in matches
        mi = CC.specialize_method(m)
        s = ctx.summary(mi)
        s === nothing && return unknown_call!(st, ctx, res, ops, :resolved_nosummary)
        push!(sums, (m.method, s, mi.sparam_vals))
    end
    return join_apply!(st, res, [(ops, m, s, sv) for (m, s, sv) in sums], "join $(callee_name(st, ops)) @ $(st.name)")
end

"""Pointer-typed intrinsic result derives from its pointer operands; integer origin taints it."""
function transfer_intrinsic!(st::MethodState, res::Core.SSAValue, args)::Nothing
    typeof_operand(st, res) <: Ptr || return
    l = loc!(st, res)
    for x in args
        t = typeof_operand(st, x)
        t <: Ptr ? unify!(st.g, l, loc!(st, x)) : (x isa Core.SSAValue || x isa Core.Argument) && t <: Integer && (st.g.tainted[find!(st.g, l)] = true)
    end
    ptrs = [x for x in args if typeof_operand(st, x) <: Ptr]
    length(ptrs) == 1 && (st.bases[res] = base_of(st, only(ptrs)))
    return
end

function transfer_foreign!(st::MethodState, ctx::Ctx, res::Core.SSAValue, e::Expr)::Nothing
    nargs = length(e.args[3]::Core.SimpleVector)
    ops = e.args[6:(5 + nargs)]
    name = foreign_name(e.args[1])
    known = name === nothing ? nothing : get(FOREIGN, name, nothing)
    known === nothing && name !== nothing && (known = gmp_mpfr(name))
    if known === nothing
        ctx.stats.foreign_unknown += 1
        ctx.stats.foreign_names[something(name, :pointer)] = get(ctx.stats.foreign_names, something(name, :pointer), 0) + 1
        tag!(st.g, loc!(st, res), :unknown)
        st.opaque = true
        CAUSE[] = "foreign $(something(name, :pointer)) @ $(st.name)"
        foreach(x -> record!(st, x, loc!(st, x), true, POSSIBLE), ops)
        foreach(x -> unify!(st.g, loc!(st, res), loc!(st, x)), ops)
        return
    end
    written, origin = known
    # known C writes change bytes of target memory, not objects it references
    foreach(p -> p <= length(ops) && record!(st, ops[p], loc!(st, ops[p]), false, DEFINITE), written)
    origin === :fresh && tag!(st.g, loc!(st, res), :fresh)
    origin isa Vector{Int} && foreach(p -> p <= length(ops) && unify!(st.g, loc!(st, res), loc!(st, ops[p])), origin)
    return
end

"""Short name of type `t` for diagnostics: type name without parameters (printing whole types is slow)."""
function short_name(@nospecialize(t))::String
    u = t isa UnionAll ? Base.unwrap_unionall(t) : t
    u isa DataType && return string(nameof(u))
    u isa Union && return "Union"
    return string(typeof(u))
end

"""Diagnostic name of callee `ops[1]`."""
function callee_name(st::MethodState, ops)::String
    isempty(ops) && return "?"
    f = CC.singleton_type(argtype(ops[1], st.ir))
    f === nothing && return string("::", short_name(typeof_operand(st, ops[1])))
    f isa Type && return short_name(f)
    f isa Function && return string(nameof(f))
    return string("::", short_name(typeof(f)))  # callable struct
end

"""Unknown callee: every operand possibly written deep; result may alias any operand."""
function unknown_call!(st::MethodState, ctx::Ctx, res::Union{Nothing, Core.SSAValue}, ops, reason::Symbol = :other)::Nothing
    ctx.stats.unknown_calls += 1
    ctx.stats.reasons[reason] = get(ctx.stats.reasons, reason, 0) + 1
    name = callee_name(st, ops)
    ctx.stats.callees[name] = get(ctx.stats.callees, name, 0) + 1
    CAUSE[] = "$reason $name @ $(st.name)"
    st.name in TRACE_UNKNOWN && println(stderr, "UNKNOWN @ $(st.name) $(reason) ", res === nothing ? "typecall" : "%$(res.id) = $(st.ir.stmts.stmt[res.id])", " :: ", [typeof_operand(st, x) for x in ops])
    # result may point into operands; unused result merges nothing
    used = res !== nothing && res.id in st.used
    if reason === :callee_unknown && (origin = callee_origin(st, ops[1])) !== nothing
        # type value from static parameter: caller knows it and resolves call
        push!(st.type_callbacks, TypeCallback(origin, [loc!(st, x) for x in ops[2:end]], arg_index.(ops[2:end]), fill(false, length(ops) - 1), CAUSE[], CURRENT_STMT[]))
        used && foreach(x -> unify!(st.g, loc!(st, res), loc!(st, x)), ops[2:end])
        return
    end
    used && tag!(st.g, loc!(st, res), :unknown)
    if reason === :callee_unknown && loc!(st, ops[1]) != 0
        # callable value: summary records call when it comes from parameter; result may be captured state
        push!(st.callbacks, Callback(loc!(st, ops[1]), [loc!(st, x) for x in ops[2:end]], CAUSE[], CURRENT_STMT[]))
        used && (unify!(st.g, loc!(st, res), content!(st.g, loc!(st, ops[1]))); foreach(x -> unify!(st.g, loc!(st, res), loc!(st, x)), ops[2:end]))
        return
    end
    st.opaque = true
    for x in ops
        l = loc!(st, x)
        record!(st, x, l, true, POSSIBLE)
        used && unify!(st.g, loc!(st, res), l)
    end
    return
end

const MAX_CANDIDATES = parse(Int, get(ENV, "S5_MAXCAND", "4"))
const PACKAGE_CAP = 64
const OWNER_JOIN = get(ENV, "S5_PKGJOIN", "1") == "1"
"""Root modules of analyzed package (corpus diagnostics)."""
const PACKAGE_ROOTS = Set{Module}()

"""Root module owning callee of call type `tt`: function type, or type a constructor builds; `nothing` if unclear."""
function owner_root(tt::Type)::Union{Nothing, Module}
    tt = Base.unwrap_unionall(tt)
    tt isa DataType && !isempty(tt.parameters) || return nothing
    ft = Base.unwrap_unionall(tt.parameters[1])
    # keyword call: owner of wrapped function
    ft === typeof(Core.kwcall) && length(tt.parameters) >= 3 && (ft = Base.unwrap_unionall(tt.parameters[3]))
    ft isa DataType || return nothing
    if ft <: Type
        isempty(ft.parameters) && return nothing
        built = Base.unwrap_unionall(ft.parameters[1])
        built isa DataType || return nothing
        ft = built
    end
    return Base.moduleroot(parentmodule(ft))
end
# `all` runs every pass (optimized IR); else name of last pass
const PASS = (pass = get(ENV, "S5_PASS", "CC: COMPACT_1"); pass == "all" ? nothing : pass)

"""Method matches inference resolved for call info `info`, when they cover every call; else `nothing`."""
function matched(info)::Union{Nothing, Vector{Core.MethodMatch}}
    if info isa CC.UnionSplitApplyCallInfo
        parts = [matched(i) for i in info.infos]
        return any(isnothing, parts) ? nothing : reduce(vcat, parts)
    end
    info isa CC.InvokeCallInfo && return [info.match]
    info isa CC.ApplyCallInfo && (info = info.call)
    info isa CC.ConstCallInfo && (info = info.call)
    infos = info isa CC.MethodMatchInfo ? [info] : info isa CC.UnionSplitInfo ? info.split : return nothing
    all(i -> i.fullmatch, infos) || return nothing
    matches = Core.MethodMatch[m for i in infos for m in i.results.matches]
    isempty(matches) && return nothing
    return matches
end

const Candidates = Union{Nothing, Vector{Tuple{Method, Core.MethodInstance}}}
# candidates per IR statement: discovery and every SCC round ask again (structural type hash is slow)
const STMT_CANDIDATES = IdDict{CC.IRCode, Dict{Int, Candidates}}()

"""Candidates of dynamic call statement `i` of `ir` with operands `args`, memoized per statement."""
stmt_candidates(ir::CC.IRCode, i::Int, args)::Candidates =
    get!(() -> candidate_instances(Tuple{(CC.widenconst(argtype(x, ir)) for x in args)...}), get!(Dict{Int, Candidates}, STMT_CANDIDATES, ir), i)

"""
Candidate instances for call type `tt`, at each method's declared signature.
Specializing on call types grows signatures without bound (vararg, nested closures); declared ones stay finite.
"""
function candidate_instances(tt::Type)::Candidates
    ms = try
        Base._methods_by_ftype(tt, MAX_CANDIDATES, Base.get_world_counter())
    catch
        nothing
    end
    if ms === nothing && OWNER_JOIN && !(owner_root(tt) in (Base, Core, nothing))
        # generic function of package or dependency: join every loaded match at declared signature
        all_ms = try
            Base._methods_by_ftype(tt, PACKAGE_CAP, Base.get_world_counter())
        catch
            nothing
        end
        all_ms isa Vector && !isempty(all_ms) && return [(m.method, declared_instance(m.method)) for m in all_ms]
    end
    (ms === nothing || isempty(ms)) && return nothing
    # concrete intersection of call and signature stays finite; else declared signature
    return [(m.method, Base.isdispatchtuple(m.spec_types) ? CC.specialize_method(m) : declared_instance(m.method)) for m in ms]
end

"""Generic call with dispatch at run time: join summaries of matching methods, else unknown."""
function dynamic_call!(
        st::MethodState, ctx::Ctx, res::Union{Nothing, Core.SSAValue}, ops, f,
        cands = candidate_instances(Tuple{(typeof_operand(st, x) for x in ops)...})
    )::Nothing
    if cands === nothing
        types = Any[typeof_operand(st, x) for x in ops]
        f === nothing && (split = split_callee(types)) !== nothing && return split_call!(st, ctx, res, ops, types, split)
        contract = contract_of(f, types)
        contract === nothing && return unknown_call!(st, ctx, res, ops, f === nothing ? :callee_unknown : :too_many_candidates)
        return apply_contract!(st, ctx, res, ops, contract)
    end
    st.assumed = true  # matching loaded methods; later package can add one
    sums = Tuple{Method, Summary, Core.SimpleVector}[]
    for (m, mi) in cands
        s = ctx.summary(mi)
        s === nothing && return unknown_call!(st, ctx, res, ops, :candidate_nosummary)
        push!(sums, (m, s, mi.sparam_vals))
    end
    ctx.stats.resolved_dynamic += 1
    return join_apply!(st, res, [(ops, m, s, sv) for (m, s, sv) in sums], "join $(callee_name(st, ops)) @ $(st.name)")
end

"""Functions of callee typed as small union of singleton functions (`Union{typeof(copyto!), typeof(adjoint!)}`)."""
function split_callee(types::Vector{Any})::Union{Nothing, Vector{Any}}
    isempty(types) && return nothing
    members = Base.uniontypes(types[1])
    (2 <= length(members) <= MAX_CANDIDATES && all(Base.issingletontype, members)) || return nothing
    return Any[m.instance for m in members]
end

"""Join over members of union callee: each member's candidates, else its contract; unknown when one has neither."""
function split_call!(st::MethodState, ctx::Ctx, res::Union{Nothing, Core.SSAValue}, ops, types::Vector{Any}, fs::Vector{Any})::Nothing
    entries = Any[]
    for f in fs
        member = Any[Core.Typeof(f); types[2:end]]
        cands = candidate_instances(Tuple{member...})
        if cands === nothing
            contract = contract_of(f, member)
            contract === nothing && return unknown_call!(st, ctx, res, ops, :callee_unknown)
            ctx.stats.reasons[:contract] = get(ctx.stats.reasons, :contract, 0) + 1
            push!(entries, (ops, nothing, contract_summary(contract, length(ops)), Core.svec()))
        else
            for (m, mi) in cands
                s = ctx.summary(mi)
                s === nothing && return unknown_call!(st, ctx, res, ops, :candidate_nosummary)
                push!(entries, (ops, m, s, mi.sparam_vals))
            end
        end
    end
    st.assumed = true
    return join_apply!(st, res, entries, "join $(join(fs, '|')) @ $(st.name)")
end

"""Whether `f` is concrete bits number type: its constructor is documented conversion (`UInt64(x)`), reading only."""
number_conversion(f)::Bool = f isa DataType && f <: Number && isconcretetype(f) && isbitstype(f)

"""Class `d` content steps below `l`, created on demand; zero for untracked `l`."""
at_depth!(g::Graph, l::Int, d::Int)::Int = (foreach(_ -> (l = l == 0 ? 0 : content!(g, l)), 1:d); l)

"""Tag class `l` as possibly aliased unless alias certainty is definite."""
maybe!(st::MethodState, l::Int, c::Certainty)::Nothing = (c == DEFINITE || tag!(st.g, l, :maybe); nothing)

"""Parameter of `m` bound by operand position `p` (operand 1 is callee)."""
param_of(m::Union{Nothing, Method}, p::Int)::Int = m !== nothing && m.isva ? min(p, Int(m.nargs)) : p

"""Apply callee summary `s` to call with `ops`; `m` is callee method (`nothing` for contract), `sparams` its instance's static parameters."""
function apply_summary!(st::MethodState, res::Union{Nothing, Core.SSAValue}, ops, m::Union{Nothing, Method}, s::Summary, sparams::Core.SimpleVector)::Nothing
    np = length(s.params)
    groups = [Any[] for _ in 1:max(np, length(ops))]
    foreach(p -> push!(groups[param_of(m, p)], ops[p]), eachindex(ops))
    opsof(j) = 1 <= j <= length(groups) ? groups[j] : Any[]
    rl = loc!(st, res)
    within = Base_[]
    for j in 1:np
        e = s.params[j]
        e == NO_EFFECT && continue
        operands = opsof(j)
        # vararg summary describes tuple elements; several operands share it, so none is definite
        shared = m !== nothing && m.isva && j == np && length(operands) > 1
        cap(c::Certainty) = shared ? min(c, POSSIBLE) : c
        CAUSE[] = shared && written(e) == DEFINITE ? "vararg $(m.name) @ $(st.name)" : isempty(s.blames[j]) ? "? $(m === nothing ? :contract : m.name)" : s.blames[j]
        for o in operands
            l = loc!(st, o)
            l == 0 && continue
            if shared
                record!(st, o, l, true, cap(written(e)))
            else
                param_cause = CAUSE[]
                bucket_cause(b) = s.joined[j][b] ? "join $(m === nothing ? :contract : m.name) @ $(st.name)" : param_cause
                CAUSE[] = bucket_cause(1); record!(st, o, l, false, e.top)
                CAUSE[] = bucket_cause(2); record!(st, o, content!(st.g, l), false, e.inner)
                CAUSE[] = bucket_cause(3); e.deep == NONE || record!(st, o, content!(st.g, content!(st.g, l)), true, e.deep)
                CAUSE[] = param_cause
            end
            # possible alias marks merged class, so source sets cannot promote writes to definite
            for (cert, target) in ((cap(e.same), l), (cap(e.inside), e.inside == NONE ? 0 : at_depth!(st.g, l, e.inside_depth)))
                cert == NONE && continue
                maybe!(st, rl, cert); unify!(st.g, rl, target); push!(within, cert == DEFINITE ? base_of(st, o) : nothing)
            end
            e.contains != NONE && rl != 0 && (c = at_depth!(st.g, rl, e.contains_depth); maybe!(st, c, cap(e.contains)); unify!(st.g, c, l))
            if e.overlap != NONE && rl != 0
                dr, dp = e.overlap_depths
                c = at_depth!(st.g, rl, dr); maybe!(st, c, cap(e.overlap)); unify!(st.g, c, at_depth!(st.g, l, dp))
            end
        end
    end
    bs = unique(within); length(bs) == 1 && res !== nothing && (st.bases[res] = only(bs))
    for (j, k, dj, dk) in s.stores, oj in opsof(j), ok in opsof(k)
        c = at_depth!(st.g, loc!(st, oj), dj)
        tag!(st.g, c, :maybe); unify!(st.g, c, at_depth!(st.g, loc!(st, ok), dk))
    end
    for (j, k) in s.merges, oj in opsof(j), ok in opsof(k)
        l = loc!(st, oj); tag!(st.g, l, :maybe); unify!(st.g, l, loc!(st, ok))
    end
    for ((j, dj), ops) in s.calls
        cops = Int[at_depth!(st.g, loc!(st, o), d) for (k, d) in ops for o in opsof(k)]
        cause = "callback $(m === nothing ? :contract : m.name) @ $(st.name)"
        foreach(o -> push!(st.callbacks, Callback(at_depth!(st.g, loc!(st, o), dj), cops, cause, CURRENT_STMT[])), opsof(j))
    end
    for (origin, pos) in s.type_calls
        type_call!(st, ops, m, sparams, origin, pos, "typecall $(m === nothing ? :contract : m.name) @ $(st.name)")
    end
    for (k, c) in s.globals
        CAUSE[] = get(s.gblames, k, "? global")
        push!(st.writes, WriteSite(global_loc!(st, k), true, c, k))
    end
    for (k, c) in s.result_globals
        maybe!(st, rl, c)
        unify!(st.g, rl, global_loc!(st, k))
        c == DEFINITE && isempty(within) && res !== nothing && (st.bases[res] = k)
    end
    st.opaque |= s.opaque
    st.assumed |= s.assumed
    s.fresh_result && rl != 0 && isempty(within) && tag!(st.g, rl, :fresh)
    return
end

# ---------------------------------------------------------------- summary extraction

function summarize(st::MethodState, nparams::Int, isva::Bool)::Summary
    g = st.g
    # classes for returned operands and arguments before tables of them
    foreach(v -> loc!(st, v), st.returns); foreach(j -> loc!(st, Core.Argument(j)), 1:nparams)
    ploc = [get(st.locs, Core.Argument(j), 0) for j in 1:nparams]
    # vararg tuple is fresh per call; its elements are caller operands
    isva && ploc[nparams] != 0 && (ploc[nparams] = content!(g, ploc[nparams]))
    preach = [reach(g, l) for l in ploc]
    TRACE[] && foreach(j -> println(stderr, "  chain $j: ", [(c, g.sources[c]) for c in preach[j]]), 1:nparams)
    TRACE[] && foreach(i -> (l = get(st.locs, Core.SSAValue(i), 0); l == 0 || println(stderr, "  %$i class ", find!(g, l), " ", g.sources[find!(g, l)])), 1:length(st.ir.stmts.stmt))
    params = fill(NO_EFFECT, nparams)
    leaf = fill((false, false, false), nparams)  # bucket has possible write from uncertainty other than join
    blames = fill("", nparams); gblames = Dict{GlobalKey, String}()
    function blame(w::WriteSite)::String
        w.cert == POSSIBLE && return isempty(w.cause) ? "? @ $(st.name)" : w.cause
        st.name in TRACE_UNKNOWN && println(stderr, "ALIAS @ $(st.name) base=$(w.base) sources=$(g.sources[find!(g, w.loc)]) %$(w.at) = ", st.ir.stmts.stmt[w.at])
        return "alias @ $(st.name)"
    end
    calls = Calls()
    for cb in st.callbacks
        recs = callback_records(g, cb, preach)
        if recs === nothing
            st.opaque = true
            CAUSE[] = cb.cause; CURRENT_STMT[] = cb.at
            foreach(l -> record!(st, nothing, l, true, POSSIBLE), (cb.callee, cb.ops...))
        else
            calls = merge_calls(calls, recs)
        end
    end
    type_calls = TypeCalls()
    for tc in st.type_callbacks
        pos = type_call_positions(g, tc, ploc, isva)
        if pos === nothing
            st.opaque = true
            CAUSE[] = tc.cause; CURRENT_STMT[] = tc.at
            foreach(l -> record!(st, nothing, l, true, POSSIBLE), tc.ops)
        else
            push!(type_calls, (tc.origin, pos))
        end
    end
    globals = Dict{GlobalKey, Certainty}()
    gkeys = Tuple{GlobalKey, Vector{Int}}[(k, reach(g, l)) for (k, l) in st.locs if k isa GlobalKey]
    # chain index where parameter reach turns into cycle; classes from there on recur at every depth
    cycle = [isempty(ch) || g.content[ch[end]] == 0 ? nothing : findfirst(==(find!(g, g.content[ch[end]])), ch) for ch in preach]
    for w in st.writes
        r = find!(g, w.loc)
        below = w.deep ? reach(g, r) : [r]
        g.tainted[r] && (st.opaque = true)
        for j in 1:nparams
            ploc[j] == 0 && continue
            c = (w.base == j || g.sources[r] == Set{Any}([j])) ? w.cert : POSSIBLE
            # depth buckets 0 (parameter), 1 (content), 2 (deeper): first chain class write reaches, down to 2 if deep or cyclic
            k = findfirst(in(below), preach[j])
            k === nothing && continue
            lo = min(k - 1, 2)
            hi = w.deep || (cycle[j] !== nothing && k >= cycle[j]) ? 2 : lo
            top, inner, deep = (b -> lo <= b <= hi ? c : NONE).((0, 1, 2))
            TRACE[] && c >= POSSIBLE && println(stderr, "  write arg $j depth $lo:$hi base=$(w.base) sources=$(g.sources[r]) deep=$(w.deep) at %$(w.at): ", st.ir.stmts.stmt[w.at])
            p = params[j]
            c == POSSIBLE && isempty(blames[j]) && (blames[j] = blame(w))
            joinish = w.cert == POSSIBLE && startswith(w.cause, "join ") && (w.base == j || g.sources[r] == Set{Any}([j]))
            c == POSSIBLE && !joinish && (leaf[j] = leaf[j] .| (top != NONE, inner != NONE, deep != NONE))
            params[j] = with(p; top = lub(p.top, top), inner = lub(p.inner, inner), deep = lub(p.deep, deep))
        end
        for (k, kr) in gkeys
            (r in kr || (w.deep && find!(g, st.locs[k]) in below)) || continue
            gc = (w.base == k || g.sources[r] == Set{Any}([k])) ? w.cert : POSSIBLE
            gc == POSSIBLE && !haskey(gblames, k) && (gblames[k] = blame(w))
            globals[k] = lub(get(globals, k, NONE), gc)
        end
    end
    result_globals = Dict{GlobalKey, Certainty}()
    fresh_result = all(v -> (l = loc!(st, v); l == 0 || g.sources[find!(g, l)] == FRESH_ONLY), st.returns)
    all_within = trues(nparams)  # definite alias needs every return to derive from parameter
    all_contains = trues(nparams)  # definite containment needs every return's content to be parameter alone
    all_overlap = trues(nparams)   # definite overlap needs every return to meet parameter content alone
    for v in st.returns
        l = loc!(st, v)
        l == 0 && continue
        r = find!(g, l); rr = reach(g, r)
        b = base_of(st, v)
        for j in 1:nparams
            ploc[j] == 0 && continue
            pr = find!(g, ploc[j])
            cert = b == j ? DEFINITE : POSSIBLE
            same = r == pr ? cert : NONE
            di = r == pr ? nothing : findfirst(==(r), preach[j])
            dc = r == pr ? nothing : findfirst(==(pr), rr)
            # definite only when every return holds parameter alone (demoted below otherwise)
            dc !== nothing && g.sources[pr] == Set{Any}([j]) || (all_contains[j] = false)
            meet = r == pr || di !== nothing || dc !== nothing ? nothing : findfirst(in(preach[j]), rr)
            (meet !== nothing && g.sources[rr[meet]] == Set{Any}([j])) || (all_overlap[j] = false)
            b == j || (all_within[j] = false)
            p = with(params[j]; same = lub(params[j].same, same))
            inside, inside_depth = lub_alias(p.inside, p.inside_depth, di === nothing ? NONE : cert, something(di, 1) - 1)
            contains, contains_depth = lub_alias(p.contains, p.contains_depth, dc === nothing ? NONE : DEFINITE, something(dc, 1) - 1)
            od = meet === nothing ? (1, 1) : (meet - 1, findfirst(==(rr[meet]), preach[j]) - 1)
            overlap, overlap_depths = lub_alias(p.overlap, p.overlap_depths, meet === nothing ? NONE : DEFINITE, od)
            params[j] = with(p; inside, inside_depth, contains, contains_depth, overlap, overlap_depths)
        end
        for (k, kr) in gkeys
            r in kr && (result_globals[k] = lub(get(result_globals, k, NONE), b == k ? DEFINITE : POSSIBLE))
            # result holds global object: caller treats as alias (coarse, keeps soundness)
            find!(g, st.locs[k]) in rr && !(r in kr) && (result_globals[k] = lub(get(result_globals, k, NONE), POSSIBLE))
        end
    end
    for j in 1:nparams
        p = params[j]
        !all_within[j] && (params[j] = p = with(p; same = min(p.same, POSSIBLE), inside = min(p.inside, POSSIBLE)))
        p.contains == DEFINITE && !all_contains[j] && (params[j] = p = with(p; contains = POSSIBLE))
        p.overlap == DEFINITE && !all_overlap[j] && (params[j] = with(p; overlap = POSSIBLE))
    end
    stores, merges = Set{NTuple{4, Int}}(), Set{Tuple{Int, Int}}()
    for j in 1:nparams, k in 1:nparams
        (j == k || ploc[j] == 0 || ploc[k] == 0) && continue
        pj, pk = find!(g, ploc[j]), find!(g, ploc[k])
        pj == pk && (push!(merges, (j, k)); continue)
        # shallowest class of k's chain inside j's chain: stored object (dk = 0) or shared elements (copy)
        a = findfirst(in(preach[j]), preach[k])
        a === nothing || push!(stores, (j, k, findfirst(==(preach[k][a]), preach[j]) - 1, a - 1))
    end
    joined = [(p.top == POSSIBLE && !l[1], p.inner == POSSIBLE && !l[2], p.deep == POSSIBLE && !l[3]) for (p, l) in zip(params, leaf)]
    return Summary(params, stores, merges, globals, st.direct, result_globals, st.opaque, fresh_result, st.assumed, calls, type_calls, joined, blames, gblames)
end

"""
Call records for callback `cb` when its callable comes from parameters alone; `nothing` when callable or operand
may come from elsewhere (global, fresh closure, unknown result): caller cannot substitute it.
"""
function callback_records(g::Graph, cb::Callback, preach::Vector{Vector{Int}})::Union{Nothing, Calls}
    cb.callee == 0 && return nothing
    r = find!(g, cb.callee)
    srcs = setdiff(g.sources[r], (:maybe,))
    (!isempty(srcs) && all(s -> s isa Int, srcs)) || return nothing
    callees = [(j, min(k - 1, 2)) for j in eachindex(preach) for k in (findfirst(==(r), preach[j]),) if k !== nothing]
    isempty(callees) && return nothing
    ops = Dict{Int, Int}()
    for l in cb.ops
        l == 0 && continue
        below = reach(g, l)
        any(c -> any(s -> s isa GlobalKey, g.sources[c]), below) && return nothing
        for j in eachindex(preach)
            k = findfirst(in(below), preach[j])
            k === nothing || (ops[j] = min(get(ops, j, 2), k - 1))
        end
    end
    return Calls(c => copy(ops) for c in callees)
end

"""
Parameter per operand of type callback `tc`: `j` when operand class is parameter `j` object alone, `-j` when it may
also be fresh object or possible alias (writes through it stay possible), 0 when it reaches fresh objects only.
`nothing` when some operand may hold other objects: positions would lose writes through them.
"""
function type_call_positions(g::Graph, tc::TypeCallback, ploc::Vector{Int}, isva::Bool)::Union{Nothing, Vector{Int}}
    pos = Int[]
    for (l, a, relaxed) in zip(tc.ops, tc.args, tc.relaxed)
        l == 0 && (push!(pos, 0); continue)
        sign = relaxed ? -1 : 1
        # vararg parameter is fresh tuple; its class holds caller operands
        1 <= a <= length(ploc) - isva && (push!(pos, sign * a); continue)
        r = find!(g, l)
        all(c -> g.sources[c] == FRESH_ONLY, reach(g, r)) && (push!(pos, 0); continue)
        j = findfirst(p -> p != 0 && find!(g, p) == r, ploc)
        j === nothing && return nothing
        srcs = g.sources[r]
        srcs == Set{Any}([j]) ? push!(pos, sign * j) : issubset(srcs, Set{Any}([j, :fresh, :maybe])) ? push!(pos, -j) : return nothing
    end
    return pos
end

"""Parameter of `m` declared `::Type{S}` for static parameter `i` (`S`), else `nothing`."""
function type_param_of(m::Method, i::Int)::Union{Nothing, Int}
    vars = TypeVar[]
    sig = m.sig
    while sig isa UnionAll
        push!(vars, sig.var); sig = sig.body
    end
    i <= length(vars) || return nothing
    return findfirst(p -> p isa DataType && p <: Type && length(p.parameters) == 1 && p.parameters[1] === vars[i], sig.parameters)
end

"""Index of static parameter operand `x` reads, else `nothing`."""
function static_param_of(ir::CC.IRCode, x)::Union{Nothing, Int}
    x isa Core.SSAValue || return nothing
    stmt = ir.stmts.stmt[x.id]
    return stmt isa Expr && stmt.head === :static_parameter ? stmt.args[1]::Int : nothing
end

"""Origin of callee `x` when it is type value caller chooses: static parameter, or parameter of type `Type`."""
function callee_origin(st::MethodState, x)::Union{Nothing, TypeOrigin}
    sp = static_param_of(st.ir, x)
    sp === nothing || return (:sparam, sp)
    x isa Core.Argument && typeof_operand(st, x) <: Type && return (:param, x.n)
    return nothing
end

"""
Target of type call record `(origin, pos)` of callee `m` (instance static parameters `sparams`) at call with `ops`
(callee first) in method instance `caller`: record in caller (`kind = :record`), call to resolve (`kind = :call`),
or `nothing` when callee type is unclear. Transfer and callee discovery both use it.
"""
function type_call_target(ir::CC.IRCode, ops, m::Union{Nothing, Method}, sparams::Core.SimpleVector, origin::TypeOrigin, pos::Vector{Int}, caller::Core.MethodInstance)
    m === nothing && return nothing
    opsof(j) = [ops[p] for p in eachindex(ops) if param_of(m, p) == abs(j)]
    all(j -> j == 0 || length(opsof(j)) == 1, pos) || return nothing
    as_record(v) = (k = findfirst(x -> x === v, caller.sparam_vals); k === nothing ? nothing : (kind = :record, origin = (:sparam, k)))
    # callee type value is operand bound to parameter `j`
    function from_operand(j)
        os = opsof(j)
        length(os) == 1 || return nothing
        o = only(os)
        t = CC.widenconst(argtype(o, ir))
        x = t isa DataType && t <: Type && length(t.parameters) == 1 ? t.parameters[1] : nothing
        x isa Type && return x
        x isa TypeVar && return as_record(x)
        sp = static_param_of(ir, o)
        sp === nothing || return (kind = :record, origin = (:sparam, sp))
        o isa Core.Argument && t <: Type && return (kind = :record, origin = (:param, o.n))
        return nothing
    end
    kind, i = origin
    v = if kind === :param
        from_operand(i)
    elseif i <= length(sparams) && sparams[i] isa Type
        sparams[i]
    elseif i <= length(sparams) && (r = as_record(sparams[i])) !== nothing
        r
    else
        # inference widened operand, so instance has fresh variable: parameter `::Type{S}` binds it
        j = type_param_of(m, i)
        j === nothing ? nothing : from_operand(j)
    end
    v isa Type || return v
    types = Any[j == 0 ? Any : CC.widenconst(argtype(only(opsof(j)), ir)) for j in pos]
    tt = Tuple{Type{v}, types...}
    # type holds caller's type variables: wrap them as caller's signature does
    caller.def isa Method && Base.has_free_typevars(tt) && (tt = Base.rewrap_unionall(tt, caller.def.sig))
    Base.has_free_typevars(tt) && return nothing
    return (kind = :call, callee = v, tt, types)
end

"""Apply type call record of callee `m` at call with `ops`: record again, queue resolution, or possible writes."""
function type_call!(st::MethodState, ops, m::Union{Nothing, Method}, sparams::Core.SimpleVector, origin::TypeOrigin, pos::Vector{Int}, cause::String)::Nothing
    target = type_call_target(st.ir, ops, m, sparams, origin, pos, st.mi)
    opsof(j) = [ops[p] for p in eachindex(ops) if m !== nothing && param_of(m, p) == abs(j)]
    if target === nothing
        st.name in TRACE_UNKNOWN && println(stderr, "TYPECALL-FAIL @ $(st.name) $(cause) origin=$(origin) pos=$(pos) m=$(m) sparams=$(sparams) ops=", [typeof_operand(st, x) for x in ops])
        st.opaque = true
        CAUSE[] = cause
        foreach(o -> record!(st, o, loc!(st, o), true, POSSIBLE), (o for j in pos if j != 0 for o in opsof(j)))
        return
    end
    classes = Int[j == 0 ? 0 : loc!(st, only(opsof(j))) for j in pos]
    args = Int[j == 0 ? 0 : arg_index(only(opsof(j))) for j in pos]
    target.kind === :record && return (push!(st.type_callbacks, TypeCallback(target.origin, classes, args, pos .< 0, cause, CURRENT_STMT[])); nothing)
    push!(st.pending, TypeCallSite(target.callee, target.tt, ClassOperand.(classes, target.types), cause, any(<(0), pos)))
    return
end

const MAX_TYPE_CALLS = 32

"""Resolve queued type calls on their classes: candidates of callee type, contract, or unknown call."""
function resolve_pending!(st::MethodState, ctx::Ctx)::Nothing
    n = 0
    while !isempty(st.pending)
        site = popfirst!(st.pending)
        n += 1
        CAUSE[] = site.cause
        ops = Any[ClassOperand(0, Type{site.callee}); site.ops]
        n0 = length(st.writes)
        if n > MAX_TYPE_CALLS
            unknown_call!(st, ctx, nothing, ops, :type_call_depth)
        else
            dynamic_call!(st, ctx, nothing, ops, site.callee, candidate_instances(site.tt))
        end
        site.capped && for i in (n0 + 1):length(st.writes)
            st.writes[i].cert == DEFINITE && (st.writes[i] = demoted(st.writes[i], site.cause))
        end
    end
    return
end

"""
Blocks that always end in `unreachable` (error paths). Writes there build error messages or logs.
Gap: a write to an argument before a caught throw is lost.
"""
function throw_blocks(ir::CC.IRCode)::Set{Int}
    blocks = ir.cfg.blocks
    throws = Set{Int}(
        b for b in eachindex(blocks)
            if (t = ir.stmts.stmt[last(blocks[b].stmts)]; t isa Core.ReturnNode && !isdefined(t, :val))
    )
    changed = true
    while changed
        changed = false
        for b in eachindex(blocks)
            b in throws && continue
            succs = blocks[b].succs
            !isempty(succs) && all(in(throws), succs) && (push!(throws, b); changed = true)
        end
    end
    return throws
end

"""Summary of one IR body given callee summaries."""
function analyze(ir::CC.IRCode, ctx::Ctx, isva::Bool = false, name::String = "?", pessimistic::Set{Int} = Set{Int}())::Summary
    st = MethodState(ir, Graph(), Dict{Any, Int}(), Dict{Any, Base_}(), WriteSite[], Set{GlobalKey}(), false, Any[], false, name, Pair{Core.SSAValue, Vector{Any}}[], pessimistic, Callback[], used_values(ir), TypeCallback[], TypeCallSite[], ir.debuginfo.def)
    throws = throw_blocks(ir)
    for (b, block) in enumerate(ir.cfg.blocks)
        b in throws && continue
        for i in block.stmts
            CURRENT_STMT[] = i
            transfer!(st, ctx, i, ir.stmts.stmt[i])
            isempty(st.pending) || resolve_pending!(st, ctx)
        end
    end
    wrong = [phi.id for (phi, later) in st.optimistic if any(v -> base_of(st, v) != st.bases[phi], later)]
    isempty(wrong) || return analyze(ir, ctx, isva, name, union(pessimistic, wrong))
    return summarize(st, length(ir.argtypes), isva)
end

# ---------------------------------------------------------------- call graph, SCCs

"""
Inferred IR of `mi`, and whether compiler proves it free of visible side effects (`@assume_effects` included);
`nothing` when inference fails.
Same steps as `Compiler.typeinf_ircode`, which drops effects.
"""
function get_ir(mi::Core.MethodInstance, stats::Stats)::Union{Nothing, Tuple{CC.IRCode, Bool}}
    mi.def isa Method || return nothing
    t0 = time()
    out = try
        interp = CC.NativeInterpreter()
        frame = CC.typeinf_frame(interp, mi, false)
        if frame === nothing
            nothing
        else
            opt = CC.OptimizationState(frame, interp)
            (CC.run_passes_ipo_safe(opt.src, opt, PASS), CC.is_effect_free(frame.result.ipo_effects))
        end
    catch
        nothing
    end
    dt = time() - t0
    stats.ir_seconds += dt
    Base.moduleroot(mi.def.module) in PACKAGE_ROOTS && (stats.pkg_ir_seconds += dt; stats.pkg_instances += 1)
    dt > 2 && (println(stderr, "slow ir ", round(dt; digits = 1), "s ", mi); flush(stderr))
    out isa Tuple{CC.IRCode, Bool} || (stats.ir_failures += 1; return nothing)
    return out
end

"""Method instance for `m` at its declared signature; type variables stay free."""
function declared_instance(m::Method)::Core.MethodInstance
    tvars = Any[]
    sig = m.sig
    while sig isa UnionAll
        push!(tvars, sig.var); sig = sig.body
    end
    return CC.specialize_method(m, m.sig, Core.svec(tvars...))
end

"""Callee instances an IR body may reach: static invokes and resolved dynamic candidates."""
function callees(ir::CC.IRCode)::Vector{Core.MethodInstance}
    out = Core.MethodInstance[]
    for (index, stmt) in enumerate(ir.stmts.stmt)
        stmt isa Expr || continue
        if stmt.head === :invoke
            ci = stmt.args[1]
            mi = ci isa Core.CodeInstance ? CC.get_ci_mi(ci) : ci
            mi isa Core.MethodInstance && push!(out, mi)
        elseif stmt.head === :call
            matches = matched(ir.stmts.info[index])
            matches === nothing || (append!(out, CC.specialize_method.(matches)); continue)
            f = CC.singleton_type(argtype(stmt.args[1], ir))
            if f === Core._apply_iterate || f === Core.invoke
                cands = if f === Core.invoke
                    invoke_candidates(ir, stmt.args)
                else
                    shape = splat_shape(ir, stmt.args)
                    shape === nothing ? nothing : candidate_instances(shape.tt)
                end
                cands === nothing || append!(out, last.(cands))
                continue
            end
            f isa Core.Builtin && continue
            types = Any[CC.widenconst(argtype(x, ir)) for x in stmt.args]
            cands = stmt_candidates(ir, index, stmt.args)
            if cands === nothing && f === nothing && (split = split_callee(types)) !== nothing
                # same members `split_call!` joins
                for g in split
                    c = candidate_instances(Tuple{Core.Typeof(g), types[2:end]...})
                    c === nothing || append!(out, last.(c))
                end
            end
            cands === nothing || append!(out, last.(cands))
        end
    end
    return unique!(out)
end

"""
Candidates of type calls that finished callees of `v` record and calls in `ir` resolve: direct calls with
inference matches, `:invoke`, and dynamic calls joined at declared signatures. Other paths fall back to unknown.
"""
function type_call_callees(eng, v::Core.MethodInstance, ir::CC.IRCode)::Vector{Core.MethodInstance}
    out = Core.MethodInstance[]
    finished(mi) = haskey(eng.summaries, mi) && !get(eng.onstack, mi, false) ? eng.summaries[mi] : nothing
    for (index, stmt) in enumerate(ir.stmts.stmt)
        stmt isa Expr || continue
        sites = if stmt.head === :invoke
            ci = stmt.args[1]
            mi = ci isa Core.CodeInstance ? CC.get_ci_mi(ci) : ci
            mi isa Core.MethodInstance && mi.def isa Method ? [(stmt.args[2:end], mi.def, mi)] : []
        elseif stmt.head === :call && CC.singleton_type(argtype(stmt.args[1], ir)) === Core.invoke && (info = ir.stmts.info[index]) isa CC.InvokeCallInfo
            # same operands as transfer: callee, then arguments after type tuple
            [(Any[stmt.args[2]; stmt.args[4:end]], info.match.method, CC.specialize_method(info.match))]
        elseif stmt.head === :call
            f = CC.singleton_type(argtype(stmt.args[1], ir))
            f isa Core.Builtin && continue
            matches = matched(ir.stmts.info[index])
            cands = matches === nothing ? candidate_instances(Tuple{(CC.widenconst(argtype(x, ir)) for x in stmt.args)...}) : [(m.method, CC.specialize_method(m)) for m in matches]
            cands === nothing ? [] : [(stmt.args, m, mi) for (m, mi) in cands]
        else
            []
        end
        for (ops, m, mi) in sites
            s = finished(mi)
            s isa Summary || continue
            for (origin, pos) in s.type_calls
                target = type_call_target(ir, ops, m, mi.sparam_vals, origin, pos, v)
                (target === nothing || target.kind !== :call) && continue
                cands = candidate_instances(target.tt)
                cands === nothing || append!(out, last.(cands))
            end
        end
    end
    return unique!(out)
end

"""Bottom-up summary engine: Tarjan over discovered instances, fixpoint per SCC."""
mutable struct Engine
    summaries::IdDict{Core.MethodInstance, Union{Nothing, Summary}}
    index::IdDict{Core.MethodInstance, Int}
    low::IdDict{Core.MethodInstance, Int}
    onstack::IdDict{Core.MethodInstance, Bool}
    stack::Vector{Core.MethodInstance}
    irs::IdDict{Core.MethodInstance, CC.IRCode}
    effect_free::IdSet{Core.MethodInstance}  # compiler proves no visible side effect
    counter::Int
    budget::Int
    stats::Stats
end

Engine(; budget::Int = 50_000) = Engine(IdDict(), IdDict(), IdDict(), IdDict(), Core.MethodInstance[], IdDict(), IdSet{Core.MethodInstance}(), 0, budget, Stats())

"""Summary lookup during analysis: finished, in-progress SCC member (current guess), or unknown."""
function lookup(eng::Engine, mi::Core.MethodInstance)::Union{Nothing, Summary}
    haskey(eng.summaries, mi) && return eng.summaries[mi]
    return nothing
end

function summary!(eng::Engine, root::Core.MethodInstance)::Union{Nothing, Summary}
    haskey(eng.summaries, root) && !get(eng.onstack, root, false) && return eng.summaries[root]
    haskey(eng.index, root) || strongconnect!(eng, root)
    return get(eng.summaries, root, nothing)
end

function strongconnect!(eng::Engine, v::Core.MethodInstance)::Nothing
    eng.counter += 1
    eng.index[v] = eng.low[v] = eng.counter
    if eng.counter > eng.budget
        eng.summaries[v] = nothing
        return
    end
    out = get_ir(v, eng.stats)
    if out === nothing
        eng.summaries[v] = nothing
        return
    end
    ir, effect_free = out
    effect_free && (push!(eng.effect_free, v); eng.stats.effect_free += 1)
    eng.stats.instances += 1
    eng.stats.instances % 100 == 0 && (
        println(
            stderr, "instances=", eng.stats.instances, " ir_s=", round(eng.stats.ir_seconds; digits = 1),
            " depth=", length(eng.stack), " at ", v
        ); flush(stderr)
    )
    eng.irs[v] = ir
    push!(eng.stack, v); eng.onstack[v] = true
    eng.summaries[v] = bottom_summary(length(ir.argtypes))
    for w in callees(ir)
        if !haskey(eng.index, w)
            strongconnect!(eng, w)
            eng.low[v] = min(eng.low[v], eng.low[w])
        elseif get(eng.onstack, w, false)
            eng.low[v] = min(eng.low[v], eng.index[w])
        end
    end
    for w in type_call_callees(eng, v, ir)
        if !haskey(eng.index, w)
            strongconnect!(eng, w)
            eng.low[v] = min(eng.low[v], eng.low[w])
        elseif get(eng.onstack, w, false)
            eng.low[v] = min(eng.low[v], eng.index[w])
        end
    end
    eng.low[v] == eng.index[v] || return
    scc = Core.MethodInstance[]
    while true
        w = pop!(eng.stack); eng.onstack[w] = false; push!(scc, w)
        w === v && break
    end
    solve_scc!(eng, scc)
    foreach(w -> (delete!(STMT_CANDIDATES, eng.irs[w]); delete!(eng.irs, w)), scc)
    return
end

"""Summary of `mi` from its IR; compiler proof of no visible side effect clears writes."""
function analyze_instance(eng::Engine, ctx::Ctx, mi::Core.MethodInstance)::Summary
    s = analyze(eng.irs[mi], ctx, mi.def isa Method && mi.def.isva, mi.def isa Method ? string(mi.def.name) : "?")
    mi in eng.effect_free || return s
    return without_writes(s, eng.stats, mi)
end

"""
`s` without argument and global writes or stores into arguments. Calls of parameter callables and type values
stay: caller resolves them to instances with own proof.
"""
function without_writes(s::Summary, stats::Stats, mi::Core.MethodInstance)::Summary
    certs = [c for p in s.params for c in (p.top, p.inner, p.deep)]
    append!(certs, values(s.globals))
    if any(!=(NONE), certs) || !isempty(s.stores)
        stats.effect_free_cleared += 1
        DEFINITE in certs && (stats.effect_free_conflicts += 1; println(stderr, "EFFECT-CONFLICT ", mi, " ", s.blames))
    end
    params = [with(p; top = NONE, inner = NONE, deep = NONE) for p in s.params]
    return Summary(
        params, Set{NTuple{4, Int}}(), s.merges, Dict{GlobalKey, Certainty}(), Set{GlobalKey}(), s.result_globals,
        s.opaque, s.fresh_result, s.assumed, s.calls, s.type_calls, fill((false, false, false), length(params)),
        fill("", length(params)), Dict{GlobalKey, String}()
    )
end

function solve_scc!(eng::Engine, scc::Vector{Core.MethodInstance})::Nothing
    t0 = time(); it0 = eng.stats.iterations
    solve_scc_inner!(eng, scc)
    dt = time() - t0
    dt > 0.05 && push!(eng.stats.slow_sccs, (dt, length(scc), eng.stats.iterations - it0, string(first(scc))))
    return
end

function solve_scc_inner!(eng::Engine, scc::Vector{Core.MethodInstance})::Nothing
    eng.stats.sccs += 1
    eng.stats.max_scc = max(eng.stats.max_scc, length(scc))
    fixpoint!(eng, scc, lub)
    must_pass!(eng, scc, Ctx(mi -> lookup(eng, mi), eng.stats))
    return
end

"""
Iterate SCC summaries with `combine(old, new)` until stable. Worklist: member reanalyzes only after summary it
read changed; analysis depends on IR and summaries it reads alone.
"""
function fixpoint!(eng::Engine, scc::Vector{Core.MethodInstance}, combine::Function)::Nothing
    members = IdSet{Core.MethodInstance}(scc)
    readers = IdDict{Core.MethodInstance, IdSet{Core.MethodInstance}}()
    work = copy(scc); queued = IdSet{Core.MethodInstance}(scc)
    runs = IdDict{Core.MethodInstance, Int}()
    while !isempty(work)
        mi = popfirst!(work); delete!(queued, mi)
        eng.stats.iterations += 1
        (runs[mi] = get(runs, mi, 0) + 1) > 200 && error("no fixpoint at $(mi)")
        reads = IdSet{Core.MethodInstance}()
        ctx = Ctx(x -> (x in members && push!(reads, x); lookup(eng, x)), eng.stats)
        old = eng.summaries[mi]::Summary
        new = combine(old, analyze_instance(eng, ctx, mi))
        foreach(w -> push!(get!(() -> IdSet{Core.MethodInstance}(), readers, w), mi), reads)
        new == old && continue
        eng.summaries[mi] = new
        for r in get(readers, mi, ())
            r in queued || (push!(work, r); push!(queued, r))
        end
    end
    return
end

"""
Recursive SCC: least fixpoint demotes joins whose candidates depend on SCC itself. Promote join-only possible
buckets to definite, then descend with meet until stable: greatest fixpoint of join agreement. Leaf uncertainty
(unknown call, alias) never promotes, so recursion cannot justify definite write by itself.
"""
function must_pass!(eng::Engine, scc::Vector{Core.MethodInstance}, ctx::Ctx)::Nothing
    MUST_PASS || return
    any(mi -> any(j -> any(j), eng.summaries[mi].joined), scc) || return
    (length(scc) > 1 || only(scc) in callees(eng.irs[only(scc)])) || return
    foreach(mi -> eng.summaries[mi] = promote_joined(eng.summaries[mi]), scc)
    fixpoint!(eng, scc, meet_writes)
    return
end

const MUST_PASS = get(ENV, "S5_MUST", "1") == "1"

promote_joined(s::Summary)::Summary = summary_with(
    s; params = [with(p; top = j[1] ? DEFINITE : p.top, inner = j[2] ? DEFINITE : p.inner, deep = j[3] ? DEFINITE : p.deep) for (p, j) in zip(s.params, s.joined)],
    joined = fill((false, false, false), length(s.params))
)

"""Write certainties of `old` lowered to `new`; everything else stays from least fixpoint."""
function meet_writes(old::Summary, new::Summary)::Summary
    # write found by least fixpoint stays at least possible
    lower(o::Certainty, n::Certainty) = o == NONE ? NONE : max(POSSIBLE, min(o, n))
    params = [with(o; top = lower(o.top, n.top), inner = lower(o.inner, n.inner), deep = lower(o.deep, n.deep)) for (o, n) in zip(old.params, new.params)]
    return summary_with(old; params, globals = Dict(k => lower(c, get(new.globals, k, c)) for (k, c) in old.globals), joined = new.joined, blames = new.blames)
end

"""Copy of `s` with fields in `changes` replaced."""
summary_with(s::Summary; changes...)::Summary = Summary((get(changes, f, getfield(s, f)) for f in fieldnames(Summary))...)

"""Run engine on deep stack; Tarjan recursion follows call depth."""
function on_big_stack(f::Function)
    t = Task(f, 1 << 30)
    schedule(t)
    return fetch(t)
end

export written, PACKAGE_ROOTS, analyze, Ctx, lookup, get_ir, TRACE, declared_instance, Certainty, NONE, POSSIBLE, DEFINITE, GlobalKey, ParamEffect, Summary, Engine, summary!, index_constants!, on_big_stack

end
