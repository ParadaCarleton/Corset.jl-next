"""Usage: julia run_lowering.jl MODE TARGET [overrides]
MODE `sandbox`: lower in fresh module, evaluate imports only. MODE `loaded`: lower inside loaded package module.
TARGET: script path, or package name in spike environment."""

include("scope_facts.jl")
using .ScopeFacts: ScopeFacts, FormResult, Provenance, lower_file!

const mode, target = ARGS[1], ARGS[2]
"overrides" in ARGS && include("overrides.jl")
results = FormResult[]
prov = Provenance()
t = @elapsed if endswith(target, ".jl")
    lower_file!(results, prov, abspath(target), Module(:Script); eval_imports = true, full = true)
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
    lower_file!(results, prov, path, root; eval_imports = (mode == "sandbox"), full = true)
end

# Warm rerun: same forms, compiled lowering code; loaded mode only (sandbox would re-run imports).
warm = mode == "loaded" ? @elapsed(
        lower_file!(
            FormResult[], Provenance(), Base.locate_package(Base.identify_package(target)), Main;
            eval_imports = false, full = true
        )
    ) : NaN
nok = count(r -> r.ok, results)
nscope = count(r -> r.ok || r.stage in (:closures, :linearize), results)
println("target=$target mode=$mode forms=$(length(results)) full_ok=$nok scope_ok=$nscope failed_scope=$(length(results) - nscope) seconds=$(round(t; digits = 2)) warm_seconds=$(round(warm; digits = 2)) lower_seconds=$(round(sum(r -> r.seconds, results; init = 0.0); digits = 2))")
println("refs exact=$(prov.exact) coarse=$(prov.coarse) line_only=$(prov.line_only)")
println("line_only by outermost macro: ", join(["$m=$n" for (m, n) in sort!(collect(prov.line_only_by_macro); by = last, rev = true)[1:min(end, 8)]], " "))
fails = Dict{String, Int}()
for r in results
    r.ok || (fails["$(r.stage): $(first(r.error, 90))"] = get(fails, "$(r.stage): $(first(r.error, 90))", 0) + 1)
end
for (msg, n) in sort!(collect(fails); by = last, rev = true)[1:min(end, 12)]
    println("  fail x$n  $msg")
end
allb = [b for r in results for b in r.bindings]
println("facts: boxed=$(count(b -> b.boxed, allb)) ambiguous_local=$(count(b -> b.ambiguous_local, allb)) used_undef=$(count(b -> b.used_undef, allb)) captured=$(count(b -> b.captured, allb)) bindings=$(length(allb)) with_bytes=$(count(b -> !isempty(b.bytes), allb))")
# Same name bound local and read as global in one form: try-scope (62) or shadowing candidate.
clashes = [
    (r, n) for r in results for n in intersect(
            Set(b.name for b in r.bindings if b.kind === :local && isempty(b.macro_name)),
            Set(b.name for b in r.bindings if b.kind === :global)
        )
]
println("local_and_global=$(length(clashes))")
endswith(target, ".jl") && foreach(((r, n),) -> println("  local_and_global $n form_line=$(r.line)"), clashes)
foreach(b -> b.boxed && println("  boxed $(b.name) $(basename(b.file)):$(b.line) bytes=$(b.bytes) macro=$(b.macro_name)"), allb)
if endswith(target, ".jl")
    for r in results, b in r.bindings
        (b.boxed || b.ambiguous_local || b.used_undef || !isempty(b.macro_name)) || continue
        println("  $(b.name) $(b.kind) line=$(b.line) bytes=$(b.bytes) boxed=$(b.boxed) ambiguous=$(b.ambiguous_local) undef=$(b.used_undef) macro=$(b.macro_name)")
    end
    for r in results
        r.ok || println("  FAIL line $(r.line): $(r.error)")
    end
end
