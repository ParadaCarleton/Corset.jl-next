# Corpus run: `julia --project=. run.jl Distances` writes results/<pkg>.txt.
include("src/S1.jl")
using .S1, .S1.StandIns, .S1.Scan, .S1.Signatures

const PKG = Symbol(ARGS[1])
const T_LOAD = @elapsed @eval using $PKG
const MOD = getfield(Main, PKG)

"Counters for one corpus run."
Base.@kwdef mutable struct Tally
    mods::Set{Module}
    method_status::Dict{Symbol, Int} = Dict{Symbol, Int}()
    notes::Dict{Symbol, Int} = Dict{Symbol, Int}()
    bottoms::Dict{Symbol, Int} = Dict{Symbol, Int}()
    sites::Dict{Tuple{Symbol, Symbol}, Int} = Dict{Tuple{Symbol, Symbol}, Int}()
    skips::Dict{Symbol, Int} = Dict{Symbol, Int}()
    findings::Vector{String} = String[]
    real_bottoms::Vector{String} = String[]
    gaps::Vector{String} = String[]
    queue::Vector{Tuple{Method, Any}} = Tuple{Method, Any}[]
    seen::Set{Tuple{Method, Any}} = Set{Tuple{Method, Any}}()
    n_sigs::Int = 0
    n_inferred::Int = 0
end

bump!(d::Dict, k) = (d[k] = get(d, k, 0) + 1)

"Infer one `(method, signature)`, record classes and sites; return `true` when inferred."
function scan!(t::Tally, m::Method, tt)::Bool
    (m, tt) in t.seen && return true
    push!(t.seen, (m, tt)); t.n_sigs += 1
    r = Scan.infer_method(m, tt)
    r isa Symbol && (bump!(t.skips, r); return false)
    t.n_inferred += 1
    ir, _ = r
    for b in Scan.classify_bottoms(ir)
        bump!(t.bottoms, b.class)
        where = "$(m.module).$(m.name) $(m.file):$(m.line)"
        (startswith(string(b.class), "real_") || b.class in (:undefined_global, :builtin, :only_default_type_works)) &&
            push!(t.real_bottoms, "$(b.class) $where -> $(b.callee)$(Tuple(b.args))")
        b.class in (:callee_throws, :opaque_in_callee, :undecided_abstract_args) && push!(t.gaps, "$(b.class) $(b.callee)$(Tuple(b.args))")
        startswith(string(b.class), "stand_in_gap") && push!(t.gaps, "$(b.class) $(b.callee)$(Tuple(b.args))")
    end
    for s in Scan.literal_sites(ir)
        bump!(t.sites, (s.kind, s.escape))
        s.escape in (:returned, :stored) && push!(
            t.findings,
            "$(s.escape) $(s.kind) $(s.callee)($(s.literal)) [$(s.stand_in)] $(s.original) vs $(s.counterfactual) @ $(m.module).$(m.name) $(Scan.stmt_line(ir, s.stmt)) ($(m.file):$(m.line))"
        )
    end
    append!(t.queue, Scan.package_callees(ir, t.mods))
    return true
end

function main(write_results::Bool)
    mods = Set{Module}([MOD]); Signatures.collect_submodules!(mods, MOD)
    t = Tally(; mods)
    methods = Signatures.package_methods(MOD)
    n_generated = count(Base.hasgenerator, methods)
    elapsed = @elapsed begin
        for m in methods
            sigs, ns = Signatures.stand_in_signatures(m, mods)
            foreach(n -> bump!(t.notes, n), unique(ns))
            has_si = any(has_stand_in, Any[p for tt in sigs for p in Base.unwrap_unionall(tt).parameters if p isa Type])
            ok = false
            for tt in sigs
                ok |= scan!(t, m, tt)
            end
            bump!(
                t.method_status, !ok ? (isempty(sigs) ? :no_signature : :failed) :
                    has_si ? :inferred_with_stand_in : :inferred_declared_types_only
            )
        end
        # Unannotated callees: analyzed through caller inference with stand-in argument types.
        reached = Set{Method}()
        while !isempty(t.queue)
            m, tt = pop!(t.queue)
            (m, tt) in t.seen && continue
            scan!(t, m, tt) && push!(reached, m)
        end
    end
    write_results || return
    mkpath("results")
    buf = IOBuffer()
    report(buf, t, methods, n_generated, elapsed, reached)
    return write("results/$(PKG).txt", replace(String(take!(buf)), homedir() => "~"))
end

function report(io::IO, t::Tally, methods::Vector{Method}, n_generated::Int, elapsed::Float64, reached::Set{Method})
    return begin
        println(io, "package $(PKG) $(pkgversion(MOD)); julia $(VERSION)")
        println(
            io, "load_s $(round(T_LOAD; digits = 2)); scan_s $(round(elapsed; digits = 2)); methods $(length(methods)); ",
            "signatures $(t.n_sigs); inferred_signatures $(t.n_inferred); generated_methods $(n_generated); ",
            "methods_reached_through_callers $(length(reached)); maxrss_mb $(Sys.maxrss() ÷ 2^20)"
        )
        section(title, d) = (println(io, "\n# ", title); foreach(p -> println(io, p[1], " ", p[2]), sort(collect(d), by = last, rev = true)))
        section("method status (own signature)", t.method_status)
        section("signature skips", t.skips)
        section("argument notes (methods with note)", t.notes)
        section("Union{} calls by class", t.bottoms)
        section("literal sites (kind, escape)", t.sites)
        println(io, "\n# escaping findings"); foreach(l -> println(io, l), sort(unique(t.findings)))
        println(io, "\n# real never-succeeds candidates"); foreach(l -> println(io, l), sort(unique(t.real_bottoms)))
        counts = Dict{String, Int}(); foreach(g -> bump!(counts, g), t.gaps)
        section("stand-in gaps and other ignored Union{} calls (distinct calls)", counts)
    end
end
main(true)
# Second run in same process: inference cache warm.
get(ENV, "S1_WARM", "") == "1" && println("warm_scan_s ", @elapsed main(false))
