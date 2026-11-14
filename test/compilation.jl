# Compilation counts: tests that code compiles once, independent of how many types it handles.

"""Whether module `inner` is `outer` or nested inside it."""
inside(inner::Module, outer::Module)::Bool = inner === outer || (parentmodule(inner) !== inner && inside(parentmodule(inner), outer))

"""Specializations of methods that `modules` and their submodules define, closures included."""
function specializations(modules::Module...)::Int
    total = Ref(0)
    Base.visit(Core.methodtable) do method
        any(mod -> inside(method.module, mod), modules) && (total[] += count(!isnothing, Base.specializations(method)))
    end
    return total[]
end
