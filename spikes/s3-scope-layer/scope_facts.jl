"""Spike S3: lower each top-level form with JuliaLowering and extract family H scope facts."""
module ScopeFacts

using JuliaLowering, JuliaSyntax
const JL = JuliaLowering
const JS = JuliaSyntax

"Binding fact with byte provenance; `bytes` empty when provenance is line-only."
struct BindingFact
    name::String
    kind::Symbol
    file::String
    bytes::UnitRange{Int}
    line::Int
    captured::Bool
    boxed::Bool
    ambiguous_local::Bool
    used_undef::Bool
    assigned::Bool
    macro_name::String
end

"Outcome of lowering one top-level form."
struct FormResult
    file::String
    line::Int
    ok::Bool
    stage::Symbol
    error::String
    seconds::Float64
    bindings::Vector{BindingFact}
end

"""Provenance counts for binding references: exact identifier bytes, other bytes, line only."""
mutable struct Provenance
    exact::Int
    coarse::Int
    line_only::Int
end

"""Classify provenance of `st` named `name` and return (file, bytes, line)."""
function locate(st::JL.SyntaxTree)::Tuple{String,UnitRange{Int},Int}
    src = JS.sourceref(st)
    src isa JS.SourceRef || return (string(src.file), 1:0, src.line)
    sf = JS.sourcefile(src)
    rng = JS.byte_range(src)
    (something(sf.filename, "?"), rng, JS.source_line(sf, first(rng)))
end

"""Name of outermost macro that produced `st`, or empty string."""
function macro_of(st::JL.SyntaxTree)::String
    mp = JS.macro_prov_end(st)
    isnothing(mp) ? "" : string(JL.est_to_expr(mp[1]))
end

"""Count reference provenance classes for every user binding id leaf in `ex`."""
function count_refs!(prov::Provenance, ctx, ex::JL.SyntaxTree)::Nothing
    if JS.head(ex) === :bindingid
        b = JL.get_binding(ctx, ex)
        b.is_internal && return nothing
        src = JS.sourceref(ex)
        if !(src isa JS.SourceRef)
            prov.line_only += 1
        elseif JS.sourcetext(src) == b.name
            prov.exact += 1
        else
            prov.coarse += 1
        end
    elseif !JS.is_leaf(ex)
        foreach(c -> count_refs!(prov, ctx, c), JS.children(ex))
    end
    nothing
end

"""Run lowering passes on `form` in `mod`; return result, declaring top-level globals in `mod`."""
function lower_form(form::JL.SyntaxTree, mod::Module, prov::Provenance; full::Bool)::FormResult
    file, _, line = locate(form)
    world = Base.get_world_counter()
    stage = :macroexpand
    t0 = time()
    try
        ex1 = JL.expand_forms_1(JL.rebase_layers(form, mod), world, true)
        stage = :desugar
        ctx2, ex2 = JL.expand_forms_2(ex1, world)
        stage = :scope
        ctx3, ex3 = JL.resolve_scopes(ctx2, ex2)
        if full
            stage = :closures
            ctx4, ex4 = JL.convert_closures(ctx3, ex3)
            stage = :linearize
            JL.linearize_ir(ctx4, ex4)
        end
        count_refs!(prov, ctx3, ex3)
        facts = BindingFact[]
        for b in ctx3.bindings.info
            b.is_internal && continue
            f, rng, ln = locate(b.node_id)
            push!(facts, BindingFact(b.name, b.kind, f, rng, ln, b.is_captured, b.is_captured && !b.unboxed,
                b.is_ambiguous_local, b.is_used_undef, b.is_assigned, macro_of(b.node_id)))
            # Declare top-level globals so later forms see soft-scope ambiguity; runs no user code.
            b.kind === :global && b.is_assigned && b.mod === mod && isempty(macro_of(b.node_id)) &&
                Core.eval(mod, Expr(:global, Expr(:(::), Symbol(b.name), Any)))
        end
        FormResult(file, line, true, stage, "", time() - t0, facts)
    catch err
        msg = first(split(sprint(showerror, err), '\n'))
        err isa JL.MacroExpansionError && (msg = "MacroExpansionError: " * err.msg * (isnothing(err.err) ? "" : " / " * first(split(sprint(showerror, err.err), "\n"))))
        FormResult(file, line, false, stage, msg, time() - t0, BindingFact[])
    end
end

"""Return string path when `form` is `include("lit")`, else nothing."""
function include_path(form::JL.SyntaxTree)::Union{Nothing,String}
    JS.head(form) === :call && JS.numchildren(form) == 2 || return nothing
    callee, arg = JS.children(form)
    JS.head(callee) === :identifier && JS.sourcetext(JS.sourceref(callee)) == "include" || return nothing
    JS.head(arg) === :string && JS.numchildren(arg) == 1 && JS.head(arg[1]) === :value || return nothing
    string(arg[1].value)
end

"""Child module `name` of `parent`: real one when loaded, else fresh sandbox."""
function child_module(parent::Module, name::Symbol)::Module
    isdefined(parent, name) && getfield(parent, name) isa Module && return getfield(parent, name)
    m = Core.eval(parent, :(module $name end))
    m
end

"""Lower every top-level form of `path` in `mod`, following literal includes."""
function lower_file!(results::Vector{FormResult}, prov::Provenance, path::String, mod::Module;
                     eval_imports::Bool, full::Bool)::Nothing
    code = read(path, String)
    st = JS.parseall(JL.SyntaxTree, code; filename=path, version=v"1.13", ignore_warnings=true)
    walk!(results, prov, JS.children(st), mod, dirname(path); eval_imports, full)
end

function walk!(results, prov, forms, mod::Module, dir::String; eval_imports::Bool, full::Bool)::Nothing
    for form in forms
        k = JS.head(form)
        if k === :toplevel
            walk!(results, prov, JS.children(form), mod, dir; eval_imports, full)
        elseif k === :module
            name = Symbol(JS.sourcetext(JS.sourceref(form[end-1])))
            walk!(results, prov, JS.children(form[end]), child_module(mod, name), dir; eval_imports, full)
        elseif (inc = include_path(form)) !== nothing
            lower_file!(results, prov, joinpath(dir, inc), mod; eval_imports, full)
        else
            if eval_imports && k in (:using, :import)
                # Imports bring macros into scope; this loads dependencies.
                Core.eval(mod, JL.est_to_expr(form))
            end
            push!(results, lower_form(form, mod, prov; full))
        end
    end
    nothing
end

end
