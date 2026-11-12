"""Fallback prototype: `Meta.lower` per top-level form; scope facts with line positions only.
Usage: julia meta_lower.jl MODE TARGET (MODE `sandbox` or `loaded`, as in run_lowering.jl)."""

"Scope fact from flisp lowering: kind, variable name, file line."
struct MetaFact
    kind::Symbol
    name::Symbol
    line::Int
end

"""Line of statement `pc` in `ci`, or `fallback` when debug info lacks it."""
function stmt_line(ci::Core.CodeInfo, pc::Int, fallback::Int)::Int
    lins = Base.IRShow.buildLineInfoNode(ci.debuginfo, nothing, pc)
    isempty(lins) ? fallback : Int(last(lins).line)
end

"""Walk `ci` and nested method bodies; collect boxed captures, slot/global name clashes."""
function scan!(facts::Vector{MetaFact}, ci::Core.CodeInfo, mod::Module, toplevel::Bool, line0::Int,
               file_globals::Set{Symbol})::Nothing
    slots = Set(ci.slotnames)
    globals_read = Dict{Symbol,Int}()
    for (pc, stmt) in enumerate(ci.code)
        ln = stmt_line(ci, pc, line0)
        # Boxed capture: `slot = Core.Box(...)` or `Core.Box()`.
        if Meta.isexpr(stmt, :(=)) && stmt.args[1] isa Core.SlotNumber && Meta.isexpr(stmt.args[2], :call) &&
           stmt.args[2].args[1] == GlobalRef(Core, :Box)
            push!(facts, MetaFact(:boxed, ci.slotnames[stmt.args[1].id], ln))
        end
        foreach_expr(stmt) do x
            x isa GlobalRef && x.mod === mod && (globals_read[x.name] = ln)
            x isa Core.CodeInfo && scan!(facts, x, mod, false, ln, file_globals)
        end
    end
    for s in slots
        s in (Symbol("#self#"), Symbol("")) && continue
        startswith(string(s), "#") && continue
        # Top-level slot named like file global: soft-scope local (footgun 61).
        toplevel && s in file_globals && push!(facts, MetaFact(:softscope_local, s, line0))
        # Same name used as local and global in one body: try-scope or shadowing candidate (62).
        haskey(globals_read, s) && push!(facts, MetaFact(:local_and_global, s, globals_read[s]))
    end
    nothing
end

"""Apply `f` to every node inside expression `x`."""
function foreach_expr(f, x)::Nothing
    f(x)
    x isa Expr && foreach(a -> foreach_expr(f, a), x.args)
    nothing
end

"Lowering outcome per top-level form."
struct MetaResult
    file::String
    line::Int
    ok::Bool
    error::String
    seconds::Float64
end

function walk!(results, facts, forms::Vector{Any}, mod::Module, dir::String, sandbox::Bool, file_globals::Set{Symbol})::Nothing
    line = 0
    file = ""
    for form in forms
        if form isa LineNumberNode
            line, file = form.line, string(form.file)
            continue
        end
        if Meta.isexpr(form, :toplevel)
            walk!(results, facts, form.args, mod, dir, sandbox, file_globals)
        elseif Meta.isexpr(form, :module)
            name = form.args[2]::Symbol
            child = isdefined(mod, name) && getfield(mod, name) isa Module ? getfield(mod, name) : Core.eval(mod, :(module $name end))
            walk!(results, facts, form.args[3].args, child, dir, sandbox, file_globals)
        elseif Meta.isexpr(form, :call) && form.args[1] === :include && form.args[2] isa String
            lower_path!(results, facts, joinpath(dir, form.args[2]), mod, sandbox, file_globals)
        else
            sandbox && Meta.isexpr(form, (:using, :import)) && try Core.eval(mod, form) catch end
            t0 = time()
            try
                lowered = Meta.lower(mod, form)
                if Meta.isexpr(lowered, :thunk)
                    scan!(facts, lowered.args[1], mod, true, line, file_globals)
                elseif Meta.isexpr(lowered, (:error, :incomplete))
                    error(string(lowered.args[1]))
                end
                # Record assigned top-level names; declare them so later forms see globals.
                Meta.isexpr(form, :(=)) && form.args[1] isa Symbol && push!(file_globals, form.args[1])
                push!(results, MetaResult(file, line, true, "", time() - t0))
            catch err
                push!(results, MetaResult(file, line, false, first(split(sprint(showerror, err), '\n')), time() - t0))
            end
        end
    end
    nothing
end

lower_path!(results, facts, path::String, mod::Module, sandbox::Bool, file_globals::Set{Symbol})::Nothing =
    walk!(results, facts, Meta.parseall(read(path, String); filename=path).args, mod, dirname(path), sandbox, file_globals)

const mode, target = ARGS[1], ARGS[2]
results, facts = MetaResult[], MetaFact[]
t = @elapsed if endswith(target, ".jl")
    lower_path!(results, facts, abspath(target), Module(:Script), true, Set{Symbol}())
else
    mode == "loaded" && Core.eval(Main, :(import $(Symbol(target))))
    lower_path!(results, facts, Base.locate_package(Base.identify_package(target)), mode == "loaded" ? Main : Module(:Sandbox),
                mode == "sandbox", Set{Symbol}())
end
nok = count(r -> r.ok, results)
println("target=$target mode=$mode forms=$(length(results)) ok=$nok failed=$(length(results) - nok) seconds=$(round(t; digits=2))")
fails = Dict{String,Int}()
foreach(r -> r.ok || (fails[first(r.error, 90)] = get(fails, first(r.error, 90), 0) + 1), results)
foreach(((m, n),) -> println("  fail x$n  $m"), sort!(collect(fails); by=last, rev=true)[1:min(end, 8)])
println("facts: ", join(["$k=$(count(f -> f.kind === k, facts))" for k in (:boxed, :softscope_local, :local_and_global)], " "))
foreach(f -> f.kind === :boxed && println("  boxed ", f.name, " line=", f.line), facts)
endswith(target, ".jl") && foreach(f -> println("  ", f.kind, " ", f.name, " line=", f.line), facts)
