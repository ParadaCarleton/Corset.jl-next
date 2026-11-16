# Corpus package from `ARGS`: modules, methods, struct types. Shared by `corpus.jl` and `bare_list.jl`.
const PKG = Symbol(only(ARGS))
const T_LOAD = @elapsed Base.require(Main, PKG)
@eval using $PKG
const ROOT = getglobal(Main, PKG)::Module

"""Package module and its submodules."""
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

"""Concrete struct types package modules define, as `Signatures.struct_stand_ins` takes them."""
function package_structs()::Vector{Type}
    found = Type[]
    for mod in MODS, n in names(mod; all = true)
        isdefined(mod, n) || continue
        v = getglobal(mod, n)
        v isa Type || continue
        u = Base.unwrap_unionall(v)
        u isa DataType && parentmodule(u) === mod && nameof(u) === n && isstructtype(u) && !isabstracttype(u) && push!(found, v)
    end
    return unique(found)
end
