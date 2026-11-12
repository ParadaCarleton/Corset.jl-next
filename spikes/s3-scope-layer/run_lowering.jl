"""Usage: julia run_lowering.jl MODE TARGET
MODE `sandbox`: lower in fresh module, evaluate imports only. MODE `loaded`: lower inside loaded package module.
TARGET: script path, or package name in spike environment."""

include("scope_facts.jl")
using .ScopeFacts: ScopeFacts, FormResult, Provenance, lower_file!

const mode, target = ARGS[1], ARGS[2]
results = FormResult[]
prov = Provenance(0, 0, 0)
t = @elapsed if endswith(target, ".jl")
    lower_file!(results, prov, abspath(target), Module(:Script); eval_imports=true, full=true)
else
    pkg = Base.identify_package(target)
    path = Base.locate_package(pkg)
    root = if mode == "loaded"
        Base.require(Main, Symbol(target))
        Main  # walk! finds loaded module by name inside Main
    else
        Module(:Sandbox)
    end
    mode == "loaded" && Core.eval(Main, :(import $(Symbol(target))))
    lower_file!(results, prov, path, root; eval_imports=(mode == "sandbox"), full=true)
end

nok = count(r -> r.ok, results)
println("target=$target mode=$mode forms=$(length(results)) ok=$nok failed=$(length(results) - nok) seconds=$(round(t; digits=2))")
println("refs exact=$(prov.exact) coarse=$(prov.coarse) line_only=$(prov.line_only)")
fails = Dict{String,Int}()
for r in results
    r.ok || (fails["$(r.stage): $(first(r.error, 90))"] = get(fails, "$(r.stage): $(first(r.error, 90))", 0) + 1)
end
for (msg, n) in sort!(collect(fails); by=last, rev=true)[1:min(end, 12)]
    println("  fail x$n  $msg")
end
if endswith(target, ".jl")
    for r in results, b in r.bindings
        (b.boxed || b.ambiguous_local || b.used_undef || !isempty(b.macro_name)) || continue
        println("  $(b.name) $(b.kind) line=$(b.line) bytes=$(b.bytes) boxed=$(b.boxed) ambiguous=$(b.ambiguous_local) undef=$(b.used_undef) macro=$(b.macro_name)")
    end
    for r in results
        r.ok || println("  FAIL line $(r.line): $(r.error)")
    end
end
