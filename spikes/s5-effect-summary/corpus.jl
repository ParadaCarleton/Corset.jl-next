# Run S5 write summary over one corpus package and compare with `!` names.
# Usage: JULIA_NUM_THREADS=2 julia +1.13 --project=. corpus.jl Distances
include("src/EffectSpike.jl")
using .EffectSpike
using Random: AbstractRNG

const PKG = Symbol(only(ARGS))
const T_LOAD = @elapsed Base.require(Main, PKG)
@eval using $PKG
const ROOT = getglobal(Main, PKG)::Module

"""Package module and its submodules."""
function package_modules(root::Module)::Set{Module}
    mods, todo = Set{Module}(), [root]
    while !isempty(todo)
        m = pop!(todo)
        m in mods && continue
        push!(mods, m)
        for n in names(m; all = true)
            isdefined(m, n) || continue
            v = getglobal(m, n)
            v isa Module && parentmodule(v) === m && v !== m && push!(todo, v)
        end
    end
    return mods
end

const MODS = package_modules(ROOT)
const METHODS = Method[]
Base.visit(m -> m.module in MODS && push!(METHODS, m), Core.methodtable)

bang(name::Symbol)::Bool = name !== :! && endswith(string(name), "!")
generated(name::Symbol)::Bool = startswith(string(name), "#")

const SYNC = Union{Base.AbstractLock, Base.GenericCondition, Threads.Event, Threads.Atomic}

"""Exemption class of global `k`, or `nothing` when write needs `!`."""
function global_class(k::GlobalKey, memo::Set{GlobalKey})::Union{Nothing, Symbol}
    k in memo && return :memo
    k.mod in MODS || return :foreign
    startswith(string(k.name), "<anonymous") && return :anonymous
    isdefined(k.mod, k.name) || return nothing
    v = getglobal(k.mod, k.name)
    v isa IO && return :io
    v isa AbstractRNG && return :rng
    v isa Task && return :task
    v isa SYNC && return :sync
    return nothing
end

"""Exemption class of parameter `j` of method `m`, or `nothing`."""
function param_class(m::Method, j::Int)::Union{Nothing, Symbol}
    j == 1 && return :self
    ps = Base.unwrap_unionall(m.sig).parameters
    t = j <= length(ps) ? ps[j] : Any
    t isa TypeVar && (t = t.ub)
    t isa Type || return nothing
    Base.isvarargtype(t) && return nothing
    t !== Union{} && t <: IO && return :io
    t !== Union{} && t <: AbstractRNG && return :rng
    return nothing
end

const STANDIN = get(ENV, "S5_STANDIN", "0") == "1"

"""Crude concrete stand-in for abstract parameter type `t` (spike S1 does this properly)."""
function standin(t)
    t isa TypeVar && return standin(t.ub)
    t isa Type || return t
    for (abstract, concrete) in ((AbstractFloat, Float64), (Real, Float64), (Number, Float64), (Integer, Int),
            (AbstractVector, Vector{Float64}), (AbstractMatrix, Matrix{Float64}), (AbstractArray, Array{Float64}),
            (AbstractString, String), (AbstractDict, Dict{Any, Any}), (IO, IOBuffer))
        concrete <: t && t <: abstract && return concrete
        t === abstract && return concrete
    end
    return t
end

"""Instance at stand-in signature when that still dispatches to `m`; else declared signature."""
function root_instance(m::Method)::Core.MethodInstance
    STANDIN || return declared_instance(m)
    ps = Base.unwrap_unionall(m.sig).parameters
    any(Base.isvarargtype, ps) && return declared_instance(m)
    tt = Tuple{(standin(p) for p in ps)...}
    ms = Base._methods_by_ftype(tt, -1, Base.get_world_counter())
    ms isa Vector || return declared_instance(m)
    i = findfirst(x -> x.method === m, ms)
    return i === nothing ? declared_instance(m) : Base.specialize_method(ms[i])
end

index_constants!()
eng = Engine(; budget = 200_000)
sums = Dict{Method, Union{Nothing, Summary}}()
const T_RUN = @elapsed on_big_stack() do
    for m in METHODS
        t0 = time()
        sums[m] = summary!(eng, root_instance(m))
        println(stderr, "root ", round(time() - t0; digits = 2), "s instances=", eng.stats.instances, " ", m.name); flush(stderr)
    end
end

# memo rule: package global, not public, written by own statements of exactly one package method
direct_writers = Dict{GlobalKey, Int}()
for s in values(sums)
    s === nothing && continue
    foreach(k -> k.mod in MODS && (direct_writers[k] = get(direct_writers, k, 0) + 1), s.direct)
end
memo = Set(k for (k, n) in direct_writers if n == 1 && !Base.ispublic(k.mod, k.name))

"""Certainty that method needs `!`, with written targets."""
function verdict(m::Method, s::Summary)::Tuple{Certainty, Vector{String}}
    c, why = NONE, String[]
    names = Base.method_argnames(m)
    for j in eachindex(s.params)
        e = s.params[j]
        w = max(e.top, e.inner)
        (w == NONE || param_class(m, j) !== nothing) && continue
        c = max(c, w); push!(why, "arg $(get(names, j, j))=$(w)")
    end
    for (k, w) in s.globals
        cls = global_class(k, memo)
        cls === :foreign && (FOREIGN_GLOBALS[k] = get(FOREIGN_GLOBALS, k, 0) + 1)
        cls === nothing || continue
        c = max(c, w); push!(why, "global $(k.mod).$(k.name)=$(w)")
    end
    return c, why
end

const FOREIGN_GLOBALS = Dict{GlobalKey, Int}()
rows = String[]
tally = Dict{Tuple{Symbol, Certainty}, Int}()
self_writes = Ref(0)
failed = Ref(0)
for m in METHODS
    s = sums[m]
    s === nothing && (failed[] += 1; continue)
    c, why = verdict(m, s)
    self_writes[] += max(s.params[1].top, s.params[1].inner) != NONE
    kind = generated(m.name) ? :generated : bang(m.name) ? :bang : :plain
    tally[(kind, c)] = get(tally, (kind, c), 0) + 1
    kind === :generated && continue
    flag = kind === :plain && c == DEFINITE ? "MISSING!" : kind === :plain && c == POSSIBLE ? "missing?" :
        kind === :bang && c == NONE ? "SPURIOUS!" : kind === :bang && c == POSSIBLE ? "bang-possible" : ""
    isempty(flag) || push!(rows, join([flag, string(m.name), string(m.file, ":", m.line), string(s.opaque), join(why, "; ")], '\t'))
end

mkpath(joinpath(@__DIR__, "results"))
open(joinpath(@__DIR__, "results", "$(PKG)$(STANDIN ? "-standin" : "")-flags.tsv"), "w") do io
    println(io, "flag\tname\tlocation\topaque\twrites")
    foreach(r -> println(io, r), sort(rows))
end
st = eng.stats
open(joinpath(@__DIR__, "results", "$(PKG)$(STANDIN ? "-standin" : "").txt"), "w") do io
    println(io, "package $(PKG) $(pkgversion(ROOT))  julia $(VERSION)  standin=$(STANDIN)")
    println(io, "load_s=$(round(T_LOAD; digits = 2)) summary_s=$(round(T_RUN; digits = 2)) ir_s=$(round(st.ir_seconds; digits = 2))")
    println(io, "package_methods=$(length(METHODS)) failed=$(failed[]) instances=$(st.instances) ir_failures=$(st.ir_failures)")
    println(io, "sccs=$(st.sccs) max_scc=$(st.max_scc) scc_iterations=$(st.iterations)")
    println(io, "unknown_calls=$(st.unknown_calls) resolved_dynamic=$(st.resolved_dynamic) foreign_unknown=$(st.foreign_unknown)")
    println(io, "memo_globals=$(sort([string(k.name) for k in memo])) self_writes=$(self_writes[])")
    for kind in (:plain, :bang, :generated), c in (DEFINITE, POSSIBLE, NONE)
        println(io, "$(kind) $(c) $(get(tally, (kind, c), 0))")
    end
    fg = sort(collect(FOREIGN_GLOBALS); by = last, rev = true)
    println(io, "foreign globals written (not counted; methods): ", length(fg), " ", [string(k.mod, ".", k.name, "=", n) for (k, n) in first(fg, 12)])
    top = sort(collect(st.foreign_names); by = last, rev = true)
    println(io, "top unknown foreign: ", first(top, 10))
end
print(read(joinpath(@__DIR__, "results", "$(PKG)$(STANDIN ? "-standin" : "").txt"), String))
