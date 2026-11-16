# Run S5 write summary over one corpus package and compare with `!` names.
# Usage: JULIA_NUM_THREADS=2 julia +1.13 --project=. corpus.jl Distances
include("src/EffectSpike.jl")
using .EffectSpike
using Random: AbstractRNG

include("package.jl")
get(ENV, "S5_PKGJOIN", "1") == "1" && push!(PACKAGE_ROOTS, ROOT)

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
    for (abstract, concrete) in (
            (AbstractFloat, Float64), (Real, Float64), (Number, Float64), (Integer, Int),
            (AbstractVector, Vector{Float64}), (AbstractMatrix, Matrix{Float64}), (AbstractArray, Array{Float64}),
            (AbstractString, String), (AbstractDict, Dict{Any, Any}), (IO, IOBuffer),
        )
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

const ROOTS = get(ENV, "S5_ROOTS", "declared")
ROOTS in ("declared", "standin") || error("S5_ROOTS must be declared or standin, got $(ROOTS)")
ROOTS == "standin" && include("corset_shim.jl")

"""Whether every argument of `m` is declared `Any`: `inference` stage reaches it only through callers."""
function unannotated(m::Method)::Bool
    ps = Base.unwrap_unionall(m.sig).parameters
    untyped(p) = p === Any || (Base.isvarargtype(p) && (!isdefined(p, :T) || p.T === Any))
    return length(ps) > 1 && all(untyped, ps[2:end])
end

const STRUCTS = ROOTS == "standin" ? Signatures.struct_stand_ins(package_structs()) : Type[]
const STRUCT_SET = Set{Type}(STRUCTS)
# Struct stand-in counts too: `Accumulator{Any, Any}` cuts path at `zero(Any)` as `ArrayStandIn{Any}` does.
ROOTS == "standin" && (EffectSpike.IS_STANDIN[] = t -> parentmodule(t) === StandIns || t in STRUCT_SET)

"""Root instances of `m`: declared signature, or stand-in signatures (none for unannotated method)."""
function roots(m::Method)::Vector{Core.MethodInstance}
    ROOTS == "declared" && return [root_instance(m)]
    unannotated(m) && return Core.MethodInstance[]
    found = Core.MethodInstance[]
    for sig in Signatures.method_signatures(m, STRUCTS).signatures
        ms = Base._methods_by_ftype(sig, -1, Base.get_world_counter())
        ms isa Vector || continue
        i = findfirst(x -> x.method === m, ms)
        i === nothing || push!(found, Base.specialize_method(ms[i]))
    end
    return unique(found)
end

const ROOT_MIS = Dict(m => roots(m) for m in METHODS)

const THROWING = Set{Method}()  # stand-in mode: method whose every analyzed instance always throws

"""
Summaries deciding verdict of each package method: roots, plus concrete package instances in stand-in mode (caller
inference). Stand-in instance that always throws decides nothing: stand-in does not fit method (coverage line).
"""
function method_summaries(e::Engine)::Dict{Method, Vector{Summary}}
    out = Dict{Method, Vector{Summary}}(m => Summary[] for m in METHODS)
    for (mi, s) in e.summaries
        (s isa Summary && mi.def isa Method && haskey(out, mi.def)) || continue
        (mi in ROOT_MIS[mi.def] || (ROOTS == "standin" && Base.isdispatchtuple(mi.specTypes))) || continue
        ROOTS == "standin" && always_throws(mi) && (push!(THROWING, mi.def); continue)
        push!(out[mi.def], s)
    end
    foreach(m -> isempty(out[m]) || delete!(THROWING, m), METHODS)
    return out
end

index_constants!()
eng = Engine(; budget = 200_000)
const T_RUN = @elapsed on_big_stack() do
    for m in METHODS, mi in ROOT_MIS[m]
        t0 = time()
        summary!(eng, mi)
        println(stderr, "root ", round(time() - t0; digits = 2), "s instances=", eng.stats.instances, " ", m.name); flush(stderr)
    end
end
sums = method_summaries(eng)

"""Whether type `t` mentions type owned by package modules."""
function mentions_package(@nospecialize(t))::Bool
    t isa TypeVar && return mentions_package(t.ub) || mentions_package(t.lb)
    t isa UnionAll && return mentions_package(t.var) || mentions_package(t.body)
    t isa Union && return mentions_package(t.a) || mentions_package(t.b)
    t isa Core.TypeofVararg && return isdefined(t, :T) && mentions_package(t.T)
    t isa DataType || return false
    parentmodule(t) in MODS && return true
    return any(mentions_package, t.parameters)
end

"""Whether summary of `mi` belongs in Base cache: method outside package, signature free of package types."""
cacheable(mi::Core.MethodInstance)::Bool = mi.def isa Method && !(mi.def.module in MODS) && !mentions_package(mi.specTypes)

# warm pass: fresh engine seeded with cacheable summaries times package work alone
warm = Engine(; budget = 200_000)
for (mi, s) in eng.summaries
    cacheable(mi) || continue
    warm.summaries[mi] = s; warm.index[mi] = warm.low[mi] = 0
    mi in eng.effect_free && push!(warm.effect_free, mi)
end
const N_CACHED = length(warm.summaries)
using Profile
get(ENV, "S5_PROFILE", "0") == "1" && Profile.init(; n = 10^7, delay = 0.002)
const T_WARM = @elapsed on_big_stack() do
    get(ENV, "S5_PROFILE", "0") == "1" && Profile.start_timer()
    for m in METHODS, mi in ROOT_MIS[m]
        summary!(warm, mi)
    end
    get(ENV, "S5_PROFILE", "0") == "1" && Profile.stop_timer()
end
if get(ENV, "S5_PROFILE", "0") == "1"
    open(joinpath(@__DIR__, "results", "$(PKG)-profile-flat.txt"), "w") do io
        Profile.print(IOContext(io, :displaysize => (10000, 400)); format = :flat, sortedby = :count, mincount = 20)
    end
    open(joinpath(@__DIR__, "results", "$(PKG)-profile-tree.txt"), "w") do io
        Profile.print(IOContext(io, :displaysize => (10000, 400)); format = :tree, maxdepth = 60, mincount = 100, noisefloor = 2.0)
    end
end
const WARM_DIFF = count(mi -> get(warm.summaries, mi, nothing) != get(eng.summaries, mi, nothing), Iterators.flatten(values(ROOT_MIS)))

# memo rule: package global, not public, written by own statements of exactly one package method
direct_writers = Dict{GlobalKey, Int}()
for ss in values(sums)
    foreach(k -> k.mod in MODS && (direct_writers[k] = get(direct_writers, k, 0) + 1), unique(Iterators.flatten(s.direct for s in ss)))
end
memo = Set(k for (k, n) in direct_writers if n == 1 && !Base.ispublic(k.mod, k.name))

"""Certainty that method needs `!`, with written targets."""
function verdict(m::Method, s::Summary)::Tuple{Certainty, Vector{String}, String}
    c, why, cause = NONE, String[], ""
    names = Base.method_argnames(m)
    for j in eachindex(s.params)
        e = s.params[j]
        w = written(e)
        (w == NONE || param_class(m, j) !== nothing) && continue
        w == POSSIBLE && isempty(cause) && (cause = s.blames[j])
        c = max(c, w); push!(why, "arg $(get(names, j, j))=$(w)")
    end
    for (k, w) in s.globals
        cls = global_class(k, memo)
        cls === :foreign && (FOREIGN_GLOBALS[k] = get(FOREIGN_GLOBALS, k, 0) + 1)
        cls === nothing || continue
        w == POSSIBLE && isempty(cause) && (cause = get(s.gblames, k, "? global"))
        c = max(c, w); push!(why, "global $(k.mod).$(k.name)=$(w)")
    end
    return c, why, cause
end

const FOREIGN_GLOBALS = Dict{GlobalKey, Int}()
rows = String[]
causes = Tuple{String, String}[]
tally = Dict{Tuple{Symbol, Certainty}, Int}()
assumed = Dict{Symbol, Int}()  # NONE verdicts that rely on contract
# Doubt test kinds of `compare/doubt.py`: doubt in code 0, open dispatch 1, blind spot 2.
const CAUSE_RANK = Dict(
    "join" => 0, "typecall" => 0, "callee_unknown" => 0, "callback" => 0, "foreign" => 0,
    "too_many_candidates" => 1, "apply_unresolved" => 1, "alias" => 2, "candidate_nosummary" => 2,
)
"""Rank of possible cause: method with doubt in code in some instance has finding, whatever other instances say."""
cause_rank(cause::String)::Int = CAUSE_RANK[first(split(cause))]

self_writes = Ref(0)
failed = Ref(0)
skipped = Ref(0)  # stand-in mode: unannotated method no analyzed caller reaches (coverage line)
throwing = Ref(0)  # stand-in mode: every instance always throws (coverage line)
lossy = Ref(0)  # stand-in mode: verdict none, but stand-in cut some path (coverage line)
for m in METHODS
    ss = sums[m]
    isempty(ss) && (m in THROWING ? (throwing[] += 1) : isempty(ROOT_MIS[m]) ? (skipped[] += 1) : (failed[] += 1); continue)
    vs = [verdict(m, s) for s in ss]
    c = maximum(first, vs)
    c == NONE && any(s -> s.lossy, ss) && (lossy[] += 1; continue)
    why = unique(collect(Iterators.flatten(v[2] for v in vs)))
    found = sort!([v[3] for v in vs if v[1] == POSSIBLE && !isempty(v[3])]; by = c -> (cause_rank(c), c))
    cause = isempty(found) ? "" : first(found)
    c == POSSIBLE && push!(causes, (string(m.name, " ", m.file, ":", m.line), isempty(cause) ? "?" : cause))
    self_writes[] += any(s -> written(s.params[1]) != NONE, ss)
    kind = generated(m.name) ? :generated : bang(m.name) ? :bang : :plain
    tally[(kind, c)] = get(tally, (kind, c), 0) + 1
    c == NONE && any(s -> s.assumed, ss) && (assumed[kind] = get(assumed, kind, 0) + 1)
    kind === :generated && continue
    flag = kind === :plain && c == DEFINITE ? "MISSING!" : kind === :plain && c == POSSIBLE ? "missing?" :
        kind === :bang && c == NONE ? "SPURIOUS!" : kind === :bang && c == POSSIBLE ? "bang-possible" : ""
    isempty(flag) || push!(rows, join([flag, string(m.name), string(m.file, ":", m.line), string(any(s -> s.opaque, ss)), join(why, "; ")], '\t'))
end

mkpath(joinpath(@__DIR__, "results"))
open(joinpath(@__DIR__, "results", "$(PKG)-$(get(ENV, "S5_TAG", "run"))-flags.tsv"), "w") do io
    println(io, "flag\tname\tlocation\topaque\twrites")
    foreach(r -> println(io, r), sort(rows))
end
st = eng.stats
open(joinpath(@__DIR__, "results", "$(PKG)-$(get(ENV, "S5_TAG", "run")).txt"), "w") do io
    println(io, "package $(PKG) $(pkgversion(ROOT))  julia $(VERSION)  standin=$(STANDIN) roots=$(ROOTS)")
    println(io, "load_s=$(round(T_LOAD; digits = 2)) summary_s=$(round(T_RUN; digits = 2)) ir_s=$(round(st.ir_seconds; digits = 2))")
    println(io, "package_methods=$(length(METHODS)) failed=$(failed[]) skipped=$(skipped[]) throwing=$(throwing[]) lossy=$(lossy[]) lossy_errors=$(EffectSpike.LOSSY_ERRORS[]) roots=$(sum(length, values(ROOT_MIS))) instances=$(st.instances) ir_failures=$(st.ir_failures)")
    println(io, "sccs=$(st.sccs) max_scc=$(st.max_scc) scc_iterations=$(st.iterations)")
    println(io, "warm_s=$(round(T_WARM; digits = 2)) warm_ir_s=$(round(warm.stats.ir_seconds; digits = 2)) warm_instances=$(warm.stats.instances) warm_pkg_ir_s=$(round(warm.stats.pkg_ir_seconds; digits = 2)) warm_pkg_instances=$(warm.stats.pkg_instances) cached=$(N_CACHED) warm_diff=$(WARM_DIFF)")
    slow = sort(warm.stats.slow_sccs; rev = true)
    println(io, "warm slow sccs total_s=$(round(sum(first, slow; init = 0.0); digits = 2)) n=$(length(slow))")
    foreach(x -> println(io, "  ", round(x[1]; digits = 3), "s size=", x[2], " rounds=", x[3], " ", first(x[4], 200)), first(slow, 25))
    println(io, "effect_free=$(st.effect_free) effect_free_cleared=$(st.effect_free_cleared) effect_free_conflicts=$(st.effect_free_conflicts)")
    println(io, "reasons=", sort(collect(st.reasons); by = last, rev = true))
    println(io, "top unknown callees=", first(sort(collect(st.callees); by = last, rev = true), 40))
    println(io, "unknown_calls=$(st.unknown_calls) resolved_dynamic=$(st.resolved_dynamic) foreign_unknown=$(st.foreign_unknown)")
    println(io, "memo_globals=$(sort([string(k.name) for k in memo])) self_writes=$(self_writes[])")
    for kind in (:plain, :bang, :generated), c in (DEFINITE, POSSIBLE, NONE)
        println(io, "$(kind) $(c) $(get(tally, (kind, c), 0))")
    end
    println(io, "none relying on contract: ", assumed)
    fg = sort(collect(FOREIGN_GLOBALS); by = last, rev = true)
    println(io, "foreign globals written (not counted; methods): ", length(fg), " ", [string(k.mod, ".", k.name, "=", n) for (k, n) in first(fg, 12)])
    top = sort(collect(st.foreign_names); by = last, rev = true)
    println(io, "top unknown foreign: ", first(top, 10))
end
open(joinpath(@__DIR__, "results", "$(PKG)-$(get(ENV, "S5_TAG", "run"))-blame.tsv"), "w") do io
    foreach(((m, c),) -> println(io, m, '\t', c), causes)
end
leaf(c) = first(split(c, " @ "))
agg = Dict{String, Int}(); foreach(((_, c),) -> agg[leaf(c)] = get(agg, leaf(c), 0) + 1, causes)
kinds = Dict{String, Int}(); foreach(((_, c),) -> (k = first(split(c)); kinds[k] = get(kinds, k, 0) + 1), causes)
open(joinpath(@__DIR__, "results", "$(PKG)-$(get(ENV, "S5_TAG", "run")).txt"), "a") do io
    println(io, "possible blame kinds: ", sort(collect(kinds); by = last, rev = true))
    println(io, "possible blame leaves: ", first(sort(collect(agg); by = last, rev = true), 40))
end
print(read(joinpath(@__DIR__, "results", "$(PKG)-$(get(ENV, "S5_TAG", "run")).txt"), String))
