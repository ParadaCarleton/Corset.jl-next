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

"""Effect of method on one parameter."""
struct ParamEffect
    top::Certainty       # writes parameter object itself
    inner::Certainty     # writes object reachable from parameter
    within::Certainty    # result points into parameter reach
    contains::Certainty  # result holds parameter
end

const NO_EFFECT = ParamEffect(NONE, NONE, NONE, NONE)

lub(a::ParamEffect, b::ParamEffect)::ParamEffect =
    ParamEffect(lub(a.top, b.top), lub(a.inner, b.inner), lub(a.within, b.within), lub(a.contains, b.contains))

"""Write summary per method instance."""
struct Summary
    params::Vector{ParamEffect}
    stores::Set{Tuple{Int, Int}}        # parameter k stored into reach of parameter j
    merges::Set{Tuple{Int, Int}}        # parameters j and k may alias after call
    globals::Dict{GlobalKey, Certainty} # globals written, own statements or callees
    direct::Set{GlobalKey}              # globals written by own statements
    result_globals::Dict{GlobalKey, Certainty}
    opaque::Bool                        # unknown callee, foreign call or untracked pointer
    fresh_result::Bool                  # result always allocated inside call
end

bottom_summary(nparams::Int)::Summary = Summary(fill(NO_EFFECT, nparams), Set{Tuple{Int, Int}}(), Set{Tuple{Int, Int}}(),
    Dict{GlobalKey, Certainty}(), Set{GlobalKey}(), Dict{GlobalKey, Certainty}(), false, true)

Base.:(==)(a::Summary, b::Summary)::Bool = all(getfield(a, f) == getfield(b, f) for f in fieldnames(Summary))

"""Merge dictionaries of certainties with `lub`."""
lub(a::Dict{GlobalKey, Certainty}, b::Dict{GlobalKey, Certainty})::Dict{GlobalKey, Certainty} = mergewith(lub, a, b)

function lub(a::Summary, b::Summary)::Summary
    length(a.params) == length(b.params) || error("summary arity mismatch")
    return Summary(lub.(a.params, b.params), a.stores ∪ b.stores, a.merges ∪ b.merges, lub(a.globals, b.globals),
        a.direct ∪ b.direct, lub(a.result_globals, b.result_globals), a.opaque || b.opaque, a.fresh_result && b.fresh_result)
end

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

"""Add source tag `src` to class of `l`."""
tag!(g::Graph, l::Int, src)::Nothing = (l == 0 || push!(g.sources[find!(g, l)], src); nothing)

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
    return find!(g, ra)
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
end

WriteSite(loc::Int, deep::Bool, cert::Certainty, base::Base_) = WriteSite(loc, deep, cert, base, CURRENT_STMT[])

const CURRENT_STMT = Ref(0)
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
    sccs::Int = 0
    max_scc::Int = 0
    iterations::Int = 0
    ir_seconds::Float64 = 0.0
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

"""IR type of operand `x`; `Any` for operands IR does not type (nested expressions)."""
argtype(x, ir::CC.IRCode)::Any = x isa Expr ? Any : CC.argextype(x, ir)

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
            v = try getglobal(m, n) catch; continue end
            v isa Module ? (parentmodule(v) === m && push!(todo, v)) :
                ismutable(v) && !(v isa Type) && !haskey(CONST_NAMES, v) && (CONST_NAMES[v] = GlobalKey(m, n))
        end
    end
    return
end

const_key(v)::GlobalKey = get(CONST_NAMES, v, GlobalKey(Core, Symbol("<anonymous ", typeof(v), ">")))

"""Class of operand `x`; zero when `x` cannot alias."""
function loc!(st::MethodState, x)::Int
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
    st.g.sources[find!(st.g, loc)] == FRESH_ONLY && return
    b = base_of(st, x)
    b isa GlobalKey && cert == DEFINITE && push!(st.direct, b)
    push!(st.writes, WriteSite(loc, deep, cert, b))
    return
end

# ---------------------------------------------------------------- builtins

const FIELD_WRITES = (setfield!, Core.setproperty!, Core.setfieldonce!, Core.modifyfield!, Core.swapfield!, Core.replacefield!)
const MEMORY_WRITES = (Core.memoryrefset!, Core.memoryrefsetonce!, Core.memoryrefmodify!, Core.memoryrefswap!, Core.memoryrefreplace!)
const GLOBAL_WRITES = (setglobal!, Core.setglobalonce!, Core.swapglobal!, Core.modifyglobal!, Core.replaceglobal!)
const POINTER_WRITES = (Core.Intrinsics.pointerset, Core.Intrinsics.atomic_pointerset, Core.Intrinsics.atomic_pointerswap,
    Core.Intrinsics.atomic_pointermodify, Core.Intrinsics.atomic_pointerreplace)
const DYNAMIC_BUILTINS = (Core._apply_iterate, Core.invoke, Core.invoke_in_world, Core.invokelatest, Core._call_in_world,
    Core._call_in_world_total, Core._call_latest, Core.finalizer)

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
for name in (:jl_rethrow, :jl_sigatomic_begin, :jl_sigatomic_end, :jl_cpu_suspend, :jl_cpu_wake, :jl_gc_safepoint,
        :jl_threadpoolid, :jl_threadid, :jl_get_next_task, :jl_set_next_task, :jl_process_events, :jl_iolock_begin,
        :jl_iolock_end, :jl_set_task_tid, :jl_get_task_tid, :jl_gc_is_in_finalizer, :jl_hrtime, :jl_get_ptls_rng,
        :jl_set_ptls_rng, :jl_gc_enable_finalizers_internal, :jl_gc_disable_finalizers_internal,
        :jl_gc_run_pending_finalizers, :jl_wakeup_thread, :jl_wakeup_threadpool, :jl_get_task_threadpoolid,
        :jl_task_get_next, :jl_switch, :jl_new_task, :jl_safe_printf, :uv_err_name, :uv_strerror, :utf8proc_charwidth,
        :uv_handle_set_data, :uv_req_set_data, :uv_req_get_data, :jl_uv_write, :free, :jl_set_precompile_field_replace)
    FOREIGN[name] = (Int[], :bits)
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
        bs = unique(base_of.((st,), vals))
        length(bs) == 1 && (st.bases[res] = only(bs))
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
        # content first: fields hold exactly stored operands, not fresh objects
        c = content_of!(st, res)
        foreach(x -> unify!(st.g, c, loc!(st, x)), e.args[2:end])
        tag!(st.g, loc!(st, res), :fresh)
    elseif e.head === :invoke
        ci = e.args[1]
        mi = ci isa Core.CodeInstance ? CC.get_ci_mi(ci) : ci
        s = mi isa Core.MethodInstance ? ctx.summary(mi) : nothing
        s === nothing ? unknown_call!(st, ctx, res, e.args[2:end]) : apply_summary!(st, res, e.args[2:end], mi.def, s)
    elseif e.head === :call
        transfer_call!(st, ctx, res, e)
    elseif e.head === :foreigncall
        transfer_foreign!(st, ctx, res, e)
    elseif e.head === :new_opaque_closure || e.head === :cfunction
        unknown_call!(st, ctx, res, e.args)
    end
    return
end

content_of!(st::MethodState, x)::Int = (l = loc!(st, x); l == 0 ? 0 : content!(st.g, l))

function transfer_call!(st::MethodState, ctx::Ctx, res::Core.SSAValue, e::Expr)::Nothing
    f = CC.singleton_type(argtype(e.args[1], st.ir))
    args = e.args[2:end]
    if f === getfield || f === Core.getproperty || f === Core.memoryrefget
        isempty(args) && return
        # pointer field points into object's own storage; other fields load referenced objects
        target = typeof_operand(st, res) <: Ptr ? loc!(st, args[1]) : content_of!(st, args[1])
        unify!(st.g, loc!(st, res), target); st.bases[res] = base_of(st, args[1])
    elseif f === Core.memoryrefnew || f === Core.ifelse || f === Core.compilerbarrier
        srcs = f === Core.ifelse ? args[2:3] : f === Core.compilerbarrier ? args[2:2] : args[1:1]
        foreach(x -> unify!(st.g, loc!(st, res), loc!(st, x)), srcs)
        bs = unique(base_of.((st,), srcs)); length(bs) == 1 && (st.bases[res] = only(bs))
    elseif f in FIELD_WRITES || f in MEMORY_WRITES
        record!(st, args[1], loc!(st, args[1]), false, DEFINITE)
        foreach(x -> unify!(st.g, content_of!(st, args[1]), loc!(st, x)), args[2:end])
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
        record!(st, args[1], loc!(st, args[1]), true, POSSIBLE)
    elseif f isa Core.IntrinsicFunction
        transfer_intrinsic!(st, res, args)
    elseif f isa Core.Builtin && !(f in DYNAMIC_BUILTINS)
        return  # remaining builtins read only: typeof, ===, isa, nfields, throw, ...
    else
        dynamic_call!(st, ctx, res, e.args, f)
    end
    return
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
    if known === nothing
        ctx.stats.foreign_unknown += 1
        ctx.stats.foreign_names[something(name, :pointer)] = get(ctx.stats.foreign_names, something(name, :pointer), 0) + 1
        tag!(st.g, loc!(st, res), :unknown)
        st.opaque = true
        foreach(x -> record!(st, x, loc!(st, x), true, POSSIBLE), ops)
        foreach(x -> unify!(st.g, loc!(st, res), loc!(st, x)), ops)
        return
    end
    written, origin = known
    foreach(p -> p <= length(ops) && record!(st, ops[p], loc!(st, ops[p]), true, DEFINITE), written)
    origin === :fresh && tag!(st.g, loc!(st, res), :fresh)
    origin isa Vector{Int} && foreach(p -> p <= length(ops) && unify!(st.g, loc!(st, res), loc!(st, ops[p])), origin)
    return
end

"""Unknown callee: every operand possibly written deep; result may alias any operand."""
function unknown_call!(st::MethodState, ctx::Ctx, res::Core.SSAValue, ops)::Nothing
    ctx.stats.unknown_calls += 1
    st.opaque = true
    tag!(st.g, loc!(st, res), :unknown)
    for x in ops
        l = loc!(st, x)
        record!(st, x, l, true, POSSIBLE)
        unify!(st.g, loc!(st, res), l)
    end
    return
end

const MAX_CANDIDATES = 4

"""
Candidate instances for call type `tt`, at each method's declared signature.
Specializing on call types grows signatures without bound (vararg, nested closures); declared ones stay finite.
"""
function candidate_instances(tt::Type)::Union{Nothing, Vector{Tuple{Method, Core.MethodInstance}}}
    ms = try
        Base._methods_by_ftype(tt, MAX_CANDIDATES, Base.get_world_counter())
    catch
        nothing
    end
    (ms === nothing || isempty(ms)) && return nothing
    return [(m.method, declared_instance(m.method)) for m in ms]
end

"""Generic call with dispatch at run time: join summaries of matching methods, else unknown."""
function dynamic_call!(st::MethodState, ctx::Ctx, res::Core.SSAValue, ops, f)::Nothing
    f === nothing && return unknown_call!(st, ctx, res, ops)
    tt = Tuple{(typeof_operand(st, x) for x in ops)...}
    cands = candidate_instances(tt)
    cands === nothing && return unknown_call!(st, ctx, res, ops)
    sums = Tuple{Method, Summary}[]
    for (m, mi) in cands
        s = ctx.summary(mi)
        s === nothing && return unknown_call!(st, ctx, res, ops)
        push!(sums, (m, s))
    end
    ctx.stats.resolved_dynamic += 1
    length(sums) == 1 && return apply_summary!(st, res, ops, sums[1]...)
    # several candidates: apply each, demote definite writes no candidate agrees on
    n0 = length(st.writes)
    for (m, s) in sums
        apply_summary!(st, res, ops, m, s)
    end
    for k in (n0 + 1):length(st.writes)
        w = st.writes[k]
        w.cert == DEFINITE && (st.writes[k] = WriteSite(w.loc, w.deep, POSSIBLE, w.base, w.at))
    end
    return
end

"""Parameter of `m` bound by operand position `p` (operand 1 is callee)."""
param_of(m::Method, p::Int)::Int = m.isva ? min(p, Int(m.nargs)) : p

function apply_summary!(st::MethodState, res::Core.SSAValue, ops, m::Method, s::Summary)::Nothing
    np = length(s.params)
    opsof(j) = [ops[p] for p in eachindex(ops) if param_of(m, p) == j]
    rl = loc!(st, res)
    within = Base_[]
    for j in 1:np
        e = s.params[j]
        e == NO_EFFECT && continue
        isva = m.isva && j == np
        for o in opsof(j)
            l = loc!(st, o)
            l == 0 && continue
            if isva  # vararg tuple holds operands: any write reaches operand deep
                record!(st, o, l, true, lub(e.top, e.inner) == NONE ? NONE : POSSIBLE)
            else
                record!(st, o, l, false, e.top)
                record!(st, o, content!(st.g, l), true, e.inner)
            end
            e.within != NONE && (unify!(st.g, rl, l); push!(within, e.within == DEFINITE ? base_of(st, o) : nothing))
            e.contains != NONE && rl != 0 && unify!(st.g, content!(st.g, rl), l)
        end
    end
    bs = unique(within); length(bs) == 1 && (st.bases[res] = only(bs))
    for (j, k) in s.stores, oj in opsof(j), ok in opsof(k)
        unify!(st.g, content_of!(st, oj), loc!(st, ok))
    end
    for (j, k) in s.merges, oj in opsof(j), ok in opsof(k)
        unify!(st.g, loc!(st, oj), loc!(st, ok))
    end
    for (k, c) in s.globals
        push!(st.writes, WriteSite(global_loc!(st, k), true, c, k))
    end
    for (k, c) in s.result_globals
        unify!(st.g, rl, global_loc!(st, k))
        c == DEFINITE && isempty(within) && (st.bases[res] = k)
    end
    st.opaque |= s.opaque
    s.fresh_result && rl != 0 && isempty(within) && tag!(st.g, rl, :fresh)
    return
end

# ---------------------------------------------------------------- summary extraction

function summarize(st::MethodState, nparams::Int)::Summary
    g = st.g
    ploc = [get(st.locs, Core.Argument(j), 0) for j in 1:nparams]
    preach = [reach(g, l) for l in ploc]
    params = fill(NO_EFFECT, nparams)
    globals = Dict{GlobalKey, Certainty}()
    gkeys = [(k, reach(g, l)) for (k, l) in st.locs if k isa GlobalKey]
    for w in st.writes
        r = find!(g, w.loc)
        below = w.deep ? reach(g, r) : [r]
        g.tainted[r] && (st.opaque = true)
        for j in 1:nparams
            ploc[j] == 0 && continue
            c = (w.base == j || g.sources[r] == Set{Any}([j])) ? w.cert : POSSIBLE
            pr = find!(g, ploc[j])
            top = r == pr ? c : NONE
            inner = (r != pr && r in preach[j]) || (w.deep && (r == pr || pr in below)) ? c : NONE
            w.deep && pr in below && r != pr && (top = c)
            (top, inner) == (NONE, NONE) && continue
            TRACE[] && max(top, inner) >= POSSIBLE && println(stderr, "  definite write arg  base=$(w.base) sources=$(g.sources[r]) deep=$(w.deep) r= pr= at %$(w.at): ", st.ir.stmts.stmt[w.at])
            p = params[j]
            params[j] = ParamEffect(lub(p.top, top), lub(p.inner, inner), p.within, p.contains)
        end
        for (k, kr) in gkeys
            (r in kr || (w.deep && find!(g, st.locs[k]) in below)) || continue
            globals[k] = lub(get(globals, k, NONE), (w.base == k || g.sources[r] == Set{Any}([k])) ? w.cert : POSSIBLE)
        end
    end
    result_globals = Dict{GlobalKey, Certainty}()
    fresh_result = all(v -> (l = loc!(st, v); l == 0 || g.sources[find!(g, l)] == FRESH_ONLY), st.returns)
    for v in st.returns
        l = loc!(st, v)
        l == 0 && continue
        r = find!(g, l); rr = reach(g, r)
        b = base_of(st, v)
        for j in 1:nparams
            ploc[j] == 0 && continue
            pr = find!(g, ploc[j])
            within = r in preach[j] ? (b == j ? DEFINITE : POSSIBLE) : NONE
            contains = (pr != r && pr in rr) ? POSSIBLE : NONE
            p = params[j]
            params[j] = ParamEffect(p.top, p.inner, lub(p.within, within), lub(p.contains, contains))
        end
        for (k, kr) in gkeys
            r in kr && (result_globals[k] = lub(get(result_globals, k, NONE), b == k ? DEFINITE : POSSIBLE))
            # result holds global object: caller treats as alias (coarse, keeps soundness)
            find!(g, st.locs[k]) in rr && !(r in kr) && (result_globals[k] = lub(get(result_globals, k, NONE), POSSIBLE))
        end
    end
    stores, merges = Set{Tuple{Int, Int}}(), Set{Tuple{Int, Int}}()
    for j in 1:nparams, k in 1:nparams
        (j == k || ploc[j] == 0 || ploc[k] == 0) && continue
        pj, pk = find!(g, ploc[j]), find!(g, ploc[k])
        pj == pk ? push!(merges, (j, k)) : pk in preach[j] && push!(stores, (j, k))
    end
    return Summary(params, stores, merges, globals, st.direct, result_globals, st.opaque, fresh_result)
end

"""
Blocks that always end in `unreachable` (error paths). Writes there build error messages or logs.
Gap: a write to an argument before a caught throw is lost.
"""
function throw_blocks(ir::CC.IRCode)::Set{Int}
    blocks = ir.cfg.blocks
    throws = Set{Int}(b for b in eachindex(blocks)
        if (t = ir.stmts.stmt[last(blocks[b].stmts)]; t isa Core.ReturnNode && !isdefined(t, :val)))
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
function analyze(ir::CC.IRCode, ctx::Ctx)::Summary
    st = MethodState(ir, Graph(), Dict{Any, Int}(), Dict{Any, Base_}(), WriteSite[], Set{GlobalKey}(), false, Any[])
    throws = throw_blocks(ir)
    for (b, block) in enumerate(ir.cfg.blocks)
        b in throws && continue
        for i in block.stmts
            CURRENT_STMT[] = i
            transfer!(st, ctx, i, ir.stmts.stmt[i])
        end
    end
    return summarize(st, length(ir.argtypes))
end

# ---------------------------------------------------------------- call graph, SCCs

"""Typed optimized IR for `mi`; `nothing` when inference fails."""
function get_ir(mi::Core.MethodInstance, stats::Stats)::Union{Nothing, CC.IRCode}
    mi.def isa Method || return nothing
    t0 = time()
    ir = try
        first(CC.typeinf_ircode(CC.NativeInterpreter(), mi, nothing))
    catch
        nothing
    end
    dt = time() - t0
    stats.ir_seconds += dt
    dt > 2 && (println(stderr, "slow ir ", round(dt; digits = 1), "s ", mi); flush(stderr))
    ir isa CC.IRCode || (stats.ir_failures += 1; return nothing)
    return ir
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
    for stmt in ir.stmts.stmt
        stmt isa Expr || continue
        if stmt.head === :invoke
            ci = stmt.args[1]
            mi = ci isa Core.CodeInstance ? CC.get_ci_mi(ci) : ci
            mi isa Core.MethodInstance && push!(out, mi)
        elseif stmt.head === :call
            f = CC.singleton_type(argtype(stmt.args[1], ir))
            (f === nothing || f isa Core.Builtin) && continue
            tt = Tuple{(CC.widenconst(argtype(x, ir)) for x in stmt.args)...}
            cands = candidate_instances(tt)
            cands === nothing || append!(out, last.(cands))
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
    counter::Int
    budget::Int
    stats::Stats
end

Engine(; budget::Int = 50_000) = Engine(IdDict(), IdDict(), IdDict(), IdDict(), Core.MethodInstance[], IdDict(), 0, budget, Stats())

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
    ir = get_ir(v, eng.stats)
    if ir === nothing
        eng.summaries[v] = nothing
        return
    end
    eng.stats.instances += 1
    eng.stats.instances % 100 == 0 && (println(stderr, "instances=", eng.stats.instances, " ir_s=", round(eng.stats.ir_seconds; digits = 1),
        " depth=", length(eng.stack), " at ", v); flush(stderr))
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
    eng.low[v] == eng.index[v] || return
    scc = Core.MethodInstance[]
    while true
        w = pop!(eng.stack); eng.onstack[w] = false; push!(scc, w)
        w === v && break
    end
    solve_scc!(eng, scc)
    foreach(w -> delete!(eng.irs, w), scc)
    return
end

function solve_scc!(eng::Engine, scc::Vector{Core.MethodInstance})::Nothing
    eng.stats.sccs += 1
    eng.stats.max_scc = max(eng.stats.max_scc, length(scc))
    ctx = Ctx(mi -> lookup(eng, mi), eng.stats)
    changed = true
    while changed
        changed = false
        eng.stats.iterations += 1
        for mi in scc
            old = eng.summaries[mi]::Summary
            new = lub(old, analyze(eng.irs[mi], ctx))
            new == old || (eng.summaries[mi] = new; changed = true)
        end
    end
    return
end

"""Run engine on deep stack; Tarjan recursion follows call depth."""
function on_big_stack(f::Function)
    t = Task(f, 1 << 30)
    schedule(t)
    return fetch(t)
end

export analyze, Ctx, lookup, get_ir, TRACE, declared_instance, Certainty, NONE, POSSIBLE, DEFINITE, GlobalKey, ParamEffect, Summary, Engine, summary!, index_constants!, on_big_stack

end
