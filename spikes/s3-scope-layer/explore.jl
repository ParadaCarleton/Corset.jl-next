using JuliaLowering, JuliaSyntax
const JL = JuliaLowering
const JS = JuliaSyntax

code = read(ARGS[1], String)
st = JS.parseall(JL.SyntaxTree, code; filename=ARGS[1], version=v"1.13", ignore_warnings=true)
mod = Module(:Sandbox)
world = Base.get_world_counter()
for form in JS.children(st)
    try
        ex = JL.expand_forms_1(JL.rebase_layers(form, mod), world, true)
        ctx2, ex2 = JL.expand_forms_2(ex, world)
        ctx3, ex3 = JL.resolve_scopes(ctx2, ex2)
        for b in ctx3.bindings.info
            b.is_internal && continue
            src = JS.sourceref(b.node_id)
            println(rpad(b.name, 8), " ", b.kind, " capt=", b.is_captured, " unboxed=", b.unboxed,
                " ambig=", b.is_ambiguous_local, " undef=", b.is_used_undef, " src=", src isa JS.SourceRef ? JS.byte_range(src) : src)
        end
        println("---")
    catch err
        println("FAIL ", JS.source_location(LineNumberNode, form), ": ", sprint(showerror, err)[1:min(end, 300)])
    end
end
