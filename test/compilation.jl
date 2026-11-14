# Compilation counts: tests that code compiles once, independent of how many types it handles.

"""Whether module `inner` is `outer` or nested inside it."""
inside(inner::Module, outer::Module)::Bool = inner === outer || (parentmodule(inner) !== inner && inside(parentmodule(inner), outer))

"""Specializations of methods that module `mod` and its submodules define, closures included."""
function specializations(mod::Module)::Int
    total = Ref(0)
    Base.visit(Core.methodtable) do method
        inside(method.module, mod) && (total[] += count(!isnothing, Base.specializations(method)))
    end
    return total[]
end
