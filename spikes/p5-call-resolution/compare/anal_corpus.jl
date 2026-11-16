# Run julia-anal mutation.jl (branch tip and name-trusting parent) over one corpus package.
# Fetch both into this directory from ParadaCarleton/julia (remote fork):
#   git show fork/1.13/strict/bang-analysis:contrib/strict/mutation.jl > mutation.jl
#   git show b88a7fe198^:contrib/strict/mutation.jl > mutation_names.jl
# Usage: julia +1.13 --project=.. anal_corpus.jl <Pkg> <outdir>
module Head
    include(joinpath(@__DIR__, "mutation.jl"))
end
module Names
    include(joinpath(@__DIR__, "mutation_names.jl"))
end

const PKG = Symbol(ARGS[1])
Base.require(Main, PKG)
@eval using $PKG
const ROOT = getglobal(Main, PKG)::Module

"""Package module and its submodules (same walk as spike corpus.jl)."""
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

"""Kind from `f(m)`, or `:error` when the analysis throws."""
safe_kind(f, m::Method)::Symbol = try
    f(m)
catch
    :error
end

memo = IdDict{Method, Head.Summary}()
t_head = @elapsed head = [safe_kind(m -> Head.kind(Head.method_summary(m, memo, ())), m) for m in METHODS]
t_names = @elapsed names_kind = [safe_kind(m -> Names.mutation_kind(Base.uncompressed_ast(m), m.nargs), m) for m in METHODS]
open(joinpath(ARGS[2], "$(PKG)-anal.tsv"), "w") do io
    println(io, "name\tlocation\thead\tnames")
    for (m, h, n) in zip(METHODS, head, names_kind)
        println(io, m.name, '\t', m.file, ':', m.line, '\t', h, '\t', n)
    end
end
println("$(PKG) methods=$(length(METHODS)) head_s=$(round(t_head; digits = 2)) names_s=$(round(t_names; digits = 2))")
