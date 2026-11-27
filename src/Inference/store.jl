# Method store: compiler edges, package methods and names they reach, method and generator digests, store entries.

"""
Package `modules`, meaning of each package name (`meanings`), and memos of method store work in one run: answers of
`names_package!`, `method_id` of each method, and digests by method id or staged key.
"""
struct StoreMemo
    modules::Set{Module}
    meanings::Dict{String, String}
    named::IdDict{Any, Bool}
    ids::IdDict{Method, String}
    codes::Dict{String, String}
end

"""Store memo of `package` that starts with method `ids` (`method_index`)."""
StoreMemo(package::PackageFacts, ids::IdDict{Method, String})::StoreMemo = StoreMemo(Set(package.modules), meanings(package), IdDict{Any, Bool}(), ids, Dict{String, String}())

"""Method instance compiler edge `edge` stands for; `nothing` for other edge (binding, method-table lookup)."""
function edge_instance(@nospecialize(edge::Any))::Union{Nothing, Core.MethodInstance}
    edge isa Core.CodeInstance && (edge = edge.def)
    edge isa Core.ABIOverride && (edge = edge.def)
    return edge isa Core.MethodInstance ? edge : nothing
end

"""Compiler edges of inference behind `edge`: those of code instance, or of first cached code instance of method instance."""
function edges_of(@nospecialize(edge::Any))::Core.SimpleVector
    edge isa Core.CodeInstance && return edge.edges
    instance = edge_instance(edge)
    return isnothing(instance) || !isdefined(instance, :cache) ? Core.svec() : instance.cache.edges
end

"""
Whether `type` names type or function of package `modules`, parameters included; `named` caches answers. Parameters
form no cycle: Julia rejects bound that names own type variable.
"""
function names_package!(named::IdDict{Any, Bool}, @nospecialize(type::Any), modules::AbstractSet{Module})::Bool
    haskey(named, type) && return named[type]
    answer = if type isa Union
        names_package!(named, type.a, modules) || names_package!(named, type.b, modules)
    elseif type isa UnionAll
        names_package!(named, type.body, modules)
    elseif type isa TypeVar
        names_package!(named, type.ub, modules)
    elseif type isa Core.TypeofVararg
        isdefined(type, :T) && names_package!(named, type.T, modules)
    elseif type isa DataType
        parentmodule(type) in modules || any(index -> names_package!(named, type.parameters[index], modules), 1:length(type.parameters))
    else
        false
    end
    named[type] = answer
    return answer
end

"""
Package methods in analyzed `files` that inference results behind compiler `edges` read, with instances of `@generated`
ones apart; then package callees and types they read (`package_callee`, `package_types!`). Call signature edge (call
with no method, `invoke`) gives callee and types too. Walk passes through package methods and through dependency
specializations that name package type (`map(f, xs)` with package `f`). `nothing` when generated instance has signature
store cannot read back (`holds_gensym`).
"""
function dependency_methods!(memo::StoreMemo, edges::AbstractVector{Any}, files::AbstractDict{String, SyntaxFile})::Union{Nothing, Tuple{Vector{Method}, Vector{Core.MethodInstance}, Set{Pair{Symbol, Core.TypeName}}, Set{Core.TypeName}}}
    found, staged, visited, stack = Method[], Core.MethodInstance[], Base.IdSet{Core.MethodInstance}(), append!(Any[], edges)
    callees, types = Set{Pair{Symbol, Core.TypeName}}(), Set{Core.TypeName}()
    while !isempty(stack)
        edge = pop!(stack)
        if edge isa Type
            add_callee!(callees, edge, memo.modules)
            package_types!(types, memo.named, edge, memo.modules)
            continue
        end
        instance = edge_instance(edge)
        (isnothing(instance) || instance in visited) && continue
        push!(visited, instance)
        add_callee!(callees, instance.specTypes, memo.modules)
        method = instance.def
        method isa Method || continue
        if haskey(files, string(method.file))
            if Base.hasgenerator(method)
                holds_gensym(instance.specTypes) && return nothing
                push!(staged, instance)
            else
                push!(found, method)
            end
        else
            names_package!(memo.named, instance.specTypes, memo.modules) || continue
        end
        package_types!(types, memo.named, instance.specTypes, memo.modules)
        append!(stack, edges_of(edge))
    end
    return found, staged, callees, types
end

"""
Type name call `signature` dispatches on: `:call` with type of function or callable object, `:new` with type that
constructor (`Type{T}`) makes. Keyword call (`Core.kwcall`) names its function. `nothing` when type variable, union or
abstract type stands there: call of any name can reach method.
"""
function dispatch_name(@nospecialize(signature::Any))::Union{Nothing, Pair{Symbol, Core.TypeName}}
    body = Base.unwrap_unionall(signature)
    body isa DataType || return nothing
    (body <: Tuple && !isempty(body.parameters)) || return nothing
    callee = body.parameters[1]
    callee === typeof(Core.kwcall) && length(body.parameters) >= 3 && (callee = body.parameters[3])
    # Parameter can be `UnionAll` itself: `Type{Circle{T}} where T`, or bare `Circle`.
    callee = Base.unwrap_unionall(callee)
    if Base.isType(callee)
        made = Base.unwrap_unionall(callee.parameters[1])
        return made isa DataType ? :new => made.name : nothing
    end
    return callee isa DataType && !isabstracttype(callee) ? :call => callee.name : nothing
end

"""Whether method `signature` has callee (`dispatch_name`) of no package `modules`: Base code can call it, and walk sees no edge."""
function foreign_callee(@nospecialize(signature::Any), modules::AbstractSet{Module})::Bool
    callee = dispatch_name(signature)
    return isnothing(callee) || !(last(callee).module in modules)
end

"""Add callee of call `signature` (`dispatch_name`) to `callees` when package `modules` own it."""
function add_callee!(callees::AbstractSet{Pair{Symbol, Core.TypeName}}, @nospecialize(signature::Any), modules::AbstractSet{Module})::Nothing
    callee = dispatch_name(signature)
    isnothing(callee) || !(last(callee).module in modules) || push!(callees, callee)
    return nothing
end

"""
Store name of `callee` (`dispatch_name`) of package `modules`: `"call M.f"` or `"new M.T"`; `nothing` for callee of
other module. Name with `#` counts: user can write one. Lowering name (`#g##0`) adds no miss: code of method using it names it.
"""
function package_callee(callee::Union{Nothing, Pair{Symbol, Core.TypeName}}, modules::AbstractSet{Module})::Union{Nothing, String}
    isnothing(callee) && return nothing
    kind, name = callee
    name.module in modules || return nothing
    return "$kind $(name.module).$(name.singletonname)"
end

"""Whether `type` is type of function bound under its name (`typeof(f)`): it has no layout, and calls name it."""
function named_function(type::DataType)::Bool
    name = type.name
    return isdefined(name.module, name.singletonname) && typeof(getglobal(name.module, name.singletonname)) === type
end

"""
Add each package type `type` names to `found`, field types of package structs included: inference reads their layout
(`type_layout`). Type of named function (`named_function`) stays out. `named` caches `names_package!` answers.
"""
function package_types!(found::AbstractSet{Core.TypeName}, named::IdDict{Any, Bool}, @nospecialize(type::Any), modules::AbstractSet{Module})::Nothing
    names_package!(named, type, modules) || return nothing
    if type isa Union
        package_types!(found, named, type.a, modules)
        package_types!(found, named, type.b, modules)
    elseif type isa UnionAll
        package_types!(found, named, type.body, modules)
    elseif type isa TypeVar
        package_types!(found, named, type.ub, modules)
    elseif type isa Core.TypeofVararg
        isdefined(type, :T) && package_types!(found, named, type.T, modules)
    elseif type isa DataType
        for parameter in type.parameters
            package_types!(found, named, parameter, modules)
        end
        name = type.name
        (name.module in modules && !named_function(type) && !(name in found)) || return nothing
        push!(found, name)
        bare = Base.unwrap_unionall(name.wrapper)
        # Tuple type with `Vararg` has no field count (`type_layout`).
        bare isa DataType || return nothing
        (isstructtype(bare) && !isnothing(Base.datatype_fieldcount(bare))) || return nothing
        for index in 1:fieldcount(bare)
            package_types!(found, named, fieldtype(bare, index), modules)
        end
    end
    return nothing
end

"""Meaning of each package name of `callees` and `types` (`meanings`), by store name, in name order."""
function read_names(memo::StoreMemo, callees::AbstractSet{Pair{Symbol, Core.TypeName}}, types::AbstractSet{Core.TypeName})::Vector{Pair{String, String}}
    labels = ["type $(name.module).$(name.singletonname)" for name in types]
    for callee in callees
        label = package_callee(callee, memo.modules)
        isnothing(label) || push!(labels, label)
    end
    return sort!([label => get(memo.meanings, label, "") for label in labels])
end

"""
Signature of each call in typed `code` of `instance`, widened. Stages look up methods for them (`package_calls`,
`reached`, failure checks), and call with many methods leaves no compiler edge. Unreached call stays out.
"""
function call_signatures(code::Core.CodeInfo, instance::Core.MethodInstance)::Vector{Any}
    parameters = CC.sptypes_from_meth_instance(instance)
    found = Any[]
    for statement in code.code
        call = statement_call(statement)
        isnothing(call) && continue
        types = Any[CC.widenconst(code_argextype(argument, code, parameters)) for argument in call.args]
        # `Tuple{Union{}}` throws.
        any(type -> type === Union{}, types) || push!(found, Tuple{types...})
    end
    return found
end

"""
Whether `type` names type lowering names, parameters included: closure (`#g##0#g##1`) or keyword body (`#f#1`). Edit can
remove name, and then serialized type cannot load. Function `f` has type `#f`, but its `singletonname` is `f`.
"""
function holds_gensym(@nospecialize(type::Any))::Bool
    type isa Union && return holds_gensym(type.a) || holds_gensym(type.b)
    type isa UnionAll && return holds_gensym(type.body)
    type isa DataType || return false
    return occursin('#', string(type.name.singletonname)) || any(holds_gensym, type.parameters)
end

"""Store key of `method` on `signature`: digest of both."""
entry_key(method::Method, signature::Type)::String = digest(Any[method.sig, signature])

"""Store name of `method`: digest of its signature, which no other method shares."""
method_id(method::Method)::String = digest(method.sig)

"""
Digest of lowered code of `method` as package load left it, macro output and `@eval` code included, with text of each
package binding it reads (`package_reads`). Closure renamed by edit has other code, so digest also checks what closure
name means.
"""
code_digest(method::Method, modules::AbstractSet{Module})::String = (code = Base.uncompressed_ast(method); digest(Any[code, package_reads(code, modules)]))

"""
Digest of code generator of `@generated` method gives for `instance`, with package bindings it reads (`package_reads`);
`nothing` digests too when generator throws.
"""
function staged_digest(instance::Core.MethodInstance, modules::AbstractSet{Module})::String
    code = CC.get_staged(instance, Base.get_world_counter())
    return digest(Any[code, code isa Core.CodeInfo ? package_reads(code, modules) : String[]])
end

"""
Text of each binding of package `modules` lowered `code` reads (`binding_text`), in order: global reference, or field
of package module (`Sub.C`, `getglobal(Sub, :C)`). Inference reads binding values; code holds names only. Module that
flows elsewhere (slot, argument) counts whole (`module_text`): field read through it hides its name.
"""
function package_reads(code::Core.CodeInfo, modules::AbstractSet{Module})::Vector{String}
    found = Set{String}()
    for statement in code.code
        # Statement defines SSA value; its uses decide whether module flows elsewhere.
        if statement isa GlobalRef
            add_binding!(found, statement, modules)
        else
            add_operands!(found, code, statement, modules)
        end
    end
    return sort!(collect(found))
end

"""Add `binding_text` of global reference `ref` to `found` when package `modules` own it (`add_field!`)."""
add_binding!(found::AbstractSet{String}, ref::GlobalRef, modules::AbstractSet{Module})::Nothing = ref.mod in modules ? add_field!(found, ref.mod, ref.name, modules) : nothing

"""
Add `binding_text` of binding `name` of `mod` to `found`, and `module_text` of each package module its constant
value holds in fields or elements (`const MODS = (Sub,)`): index into constant can reach module.
"""
function add_field!(found::AbstractSet{String}, mod::Module, name::Symbol, modules::AbstractSet{Module})::Nothing
    push!(found, binding_text(mod, name))
    (isdefined(mod, name) && isconst(mod, name)) || return nothing
    value = getglobal(mod, name)
    value isa Module || foreach(held -> push!(found, module_text(held, modules)), held_modules(value, modules))
    return nothing
end

"""
Address of boxed `value`: names shared part of object graph, so walk counts it once. `objectid` hashes immutable contents,
so deep chain overflows. Caller keeps each value alive: fresh box of inline field can take address of freed box.
"""
heap_address(@nospecialize(value::Any))::Ptr{Cvoid} = @ccall jl_value_ptr(value::Any)::Ptr{Cvoid}

"""Package modules that `value` holds in fields or elements, transitively; type values hold none."""
function held_modules(@nospecialize(value::Any), modules::AbstractSet{Module})::Set{Module}
    held, pending, visited, kept = Set{Module}(), Any[value], Set{Ptr{Cvoid}}(), Any[]
    # `kept` holds each visited object, so its `heap_address` stays its own.
    # Work stack: constant linked list can be deeper than call stack.
    while !isempty(pending)
        current = pop!(pending)
        if current isa Module
            current in modules && push!(held, current)
            continue
        end
        (isbits(current) || current isa Union{Type, Core.TypeName, Method, Core.MethodInstance, Core.CodeInstance}) && continue
        address = heap_address(current)
        address in visited && continue
        push!(visited, address)
        push!(kept, current)
        if current isa Memory
            # Bits element type holds no module: big numeric constants cost nothing. `Tuple{Module}` holds one.
            isbitstype(eltype(current)) || append!(pending, (current[index] for index in eachindex(current) if isassigned(current, index)))
        else
            append!(pending, (getfield(current, index) for index in 1:nfields(current) if isdefined(current, index)))
        end
    end
    return held
end

"""Lowered statement types whose fields hold operands: `return`, branch, and SSA form nodes."""
const OPERAND_NODES = Union{Core.ReturnNode, Core.GotoIfNot, Core.PiNode, Core.UpsilonNode, Core.PhiNode, Core.PhiCNode, Core.EnterNode}

"""Add reads of operand `value` of lowered `code` to `found` (`package_reads`): package module operand counts whole."""
function add_reads!(found::AbstractSet{String}, code::Core.CodeInfo, @nospecialize(value::Any), modules::AbstractSet{Module})::Nothing
    held = module_value(code, value, modules)
    isnothing(held) || push!(found, module_text(held, modules))
    if value isa GlobalRef
        add_binding!(found, value, modules)
    else
        add_operands!(found, code, value, modules)
    end
    return nothing
end

"""Add reads of operands of expression or node `value` of lowered `code` to `found` (`add_reads!`)."""
function add_operands!(found::AbstractSet{String}, code::Core.CodeInfo, @nospecialize(value::Any), modules::AbstractSet{Module})::Nothing
    if value isa Expr
        field = module_field(code, value, modules)
        isnothing(field) || add_field!(found, field..., modules)
        # Holder of resolved field only names its module.
        for (position, argument) in enumerate(value.args)
            isnothing(field) || position != 2 || continue
            add_reads!(found, code, argument, modules)
        end
    elseif value isa OPERAND_NODES
        foreach(index -> isdefined(value, index) && add_reads!(found, code, getfield(value, index), modules), 1:nfields(value))
    elseif value isa Vector{Any}
        foreach(operand -> add_reads!(found, code, operand, modules), value)
    end
    return nothing
end

"""Package module and name that `getproperty` or `getglobal` call `call` of lowered `code` reads (`Sub.C`); else `nothing`."""
function module_field(code::Core.CodeInfo, call::Expr, modules::AbstractSet{Module})::Union{Nothing, Tuple{Module, Symbol}}
    (call.head === :call && length(call.args) == 3) || return nothing
    reader = constant_value(code, call.args[1])
    (isnothing(reader) || !(something(reader) === getproperty || something(reader) === getglobal)) && return nothing
    holder, field = module_value(code, call.args[2], modules), call.args[3]
    return !isnothing(holder) && field isa QuoteNode && field.value isa Symbol ? (holder, field.value::Symbol) : nothing
end

"""Value of constant global that operand `value` of lowered `code` names, directly or through SSA value; else `nothing`."""
function constant_value(code::Core.CodeInfo, @nospecialize(value::Any))::Union{Nothing, Some{Any}}
    value isa Core.SSAValue && return constant_value(code, code.code[value.id])
    value isa GlobalRef || return nothing
    (isdefined(value.mod, value.name) && isconst(value.mod, value.name)) || return nothing
    return Some{Any}(getglobal(value.mod, value.name))
end

"""Package module that operand `value` of lowered `code` holds: literal, constant global, or its constant field; else `nothing`."""
function module_value(code::Core.CodeInfo, @nospecialize(value::Any), modules::AbstractSet{Module})::Union{Nothing, Module}
    value isa Module && return value in modules ? value : nothing
    value isa Core.SSAValue && return module_value(code, code.code[value.id], modules)
    place = value isa GlobalRef ? (value.mod, value.name) : value isa Expr ? module_field(code, value, modules) : nothing
    isnothing(place) && return nothing
    holder, name = place
    (isdefined(holder, name) && isconst(holder, name)) || return nothing
    held = getglobal(holder, name)
    return held isa Module && held in modules ? held : nothing
end

"""Text of every binding of package module `mod` and of package modules it holds (`binding_text`): code reads it whole."""
function module_text(mod::Module, modules::AbstractSet{Module})::String
    texts, pending, visited = String[], [mod], Set{Module}()
    while !isempty(pending)
        current = pop!(pending)
        current in visited && continue
        push!(visited, current)
        # Names with `#` count too: `getglobal(holder, Symbol("#C"))` reads them.
        for name in names(current; all = true)
            push!(texts, binding_text(current, name))
            # Module in constant container counts too: index can reach it (`MODS[1].C`).
            isdefined(current, name) && isconst(current, name) && append!(pending, held_modules(getglobal(current, name), modules))
        end
    end
    return "module $mod $(digest(sort!(texts)))"
end

"""Text of binding `name` of `mod` inference reads: shape text of constant (`constant_text`), type of global, or none."""
function binding_text(mod::Module, name::Symbol)::String
    isdefined(mod, name) || return "$mod.$name"
    isconst(mod, name) && return "$mod.$name constant $(constant_text(getglobal(mod, name)))"
    return "$mod.$name global $(digest(Core.get_binding_type(mod, name)))"
end

"""Methods defined in analyzed `files` by `method_id`, keyword bodies and closures included; `ids` keeps each one's id."""
function method_index(files::AbstractDict{String, SyntaxFile})::Tuple{Dict{String, Method}, IdDict{Method, String}}
    ids = IdDict{Method, String}()
    Base.visit(method -> haskey(files, string(method.file)) && (ids[method] = method_id(method)), Core.methodtable)
    return Dict(id => method for (method, id) in ids), ids
end

# corset: allow bang-convention -- memo of code digests; result never changes
"""
Entry `store` holds under `key` when file of method keeps its hash in `hashes`, each package name entry read keeps its
meaning (`meanings`), each method it read keeps its code, and each generator it read gives same code. `index` finds
methods by id; `memo` caches digests. Generator runs under crash `journal` (`journaled_digest`).
"""
function valid_entry(store::Store, key::String, hashes::AbstractDict{String, String}, index::AbstractDict{String, Method}, memo::StoreMemo, journal::Union{Nothing, Journal})::Union{Nothing, Entry}
    entry = get(store, key, nothing)
    (isnothing(entry) || get(hashes, first(entry.file), "") != last(entry.file)) && return nothing
    for (name, meaning) in entry.names
        get(memo.meanings, name, "") == meaning || return nothing
    end
    for (id, code) in entry.methods
        method = get(index, id, nothing)
        (isnothing(method) || get!(() -> code_digest(method, memo.modules), memo.codes, id) != code) && return nothing
    end
    for staged in entry.staged
        method = get(index, staged.method, nothing)
        isnothing(method) && return nothing
        specialized = instance(method, deserialize(IOBuffer(staged.signature))::Type)
        isnothing(specialized) && return nothing
        code = cached_digest(memo, journal, specialized, staged.key)
        (isnothing(code) || code != staged.code) && return nothing
    end
    return entry
end

"""
Store entry of `inferred` result of `site` on `signature`, whose inferences gave compiler `edges`, call signatures of
typed code included (`call_signatures`); `nothing` when walk gives none (`dependency_methods!`). `memo` caches ids and
digests.
"""
function entry!(memo::StoreMemo, site::MethodSite, signature::Type, inferred::Inferred, edges::AbstractVector{Any}, files::AbstractDict{String, SyntaxFile}, hashes::AbstractDict{String, String})::Union{Nothing, Entry}
    read = dependency_methods!(memo, edges, files)
    isnothing(read) && return nothing
    found, generated, callees, types = read
    if Base.hasgenerator(site.method)
        holds_gensym(signature) && return nothing
        push!(generated, something(instance(site.method, signature)))
    else
        push!(found, site.method)
    end
    package_types!(types, memo.named, signature, memo.modules)
    # Unit start record of crash journal covers generators that run here.
    digests, records = method_digests!(memo, found), Staged[something(staged_record(memo, specialized, nothing)) for specialized in generated]
    return Entry(site.file.path => hashes[site.file.path], digests, records, read_names(memo, callees, types), serialized(inferred), UInt8[])
end

"""Digest of each method in `found` by id, once per id; `memo` caches ids and digests."""
function method_digests!(memo::StoreMemo, found::AbstractVector{Method})::Vector{Pair{String, String}}
    methods = Dict(get!(() -> method_id(method), memo.ids, method) => method for method in found)
    return [id => get!(() -> code_digest(method, memo.modules), memo.codes, id) for (id, method) in methods]
end

# corset: allow bang-convention -- memo of method ids and digests; crash journal records progress
"""
Store record of generator instance `specialized`; `memo` caches method ids and digests. Generator runs under crash
`journal` (`journaled_digest`); `nothing` when earlier run crashed there.
"""
function staged_record(memo::StoreMemo, specialized::Core.MethodInstance, journal::Union{Nothing, Journal})::Union{Nothing, Staged}
    method, key = specialized.def::Method, entry_key(specialized.def::Method, specialized.specTypes)
    code = cached_digest(memo, journal, specialized, key)
    isnothing(code) && return nothing
    return Staged(get!(() -> method_id(method), memo.ids, method), serialized(specialized.specTypes), key, code)
end

# corset: allow bang-convention -- memo of code digests; crash journal records progress
"""`journaled_digest` of `specialized` that `memo` keeps under staged `key`; crashed key keeps none."""
function cached_digest(memo::StoreMemo, journal::Union{Nothing, Journal}, specialized::Core.MethodInstance, key::String)::Union{Nothing, String}
    haskey(memo.codes, key) && return memo.codes[key]
    code = journaled_digest(journal, specialized, key, memo.modules)
    isnothing(code) || (memo.codes[key] = code)
    return code
end

"""
`staged_digest` of `specialized` with package `modules` between start and finish records of `"staged "` plus staged
`key` in crash `journal`: generator can abort process. `nothing` when earlier run crashed there.
"""
function journaled_digest(journal::Union{Nothing, Journal}, specialized::Core.MethodInstance, key::String, modules::AbstractSet{Module})::Union{Nothing, String}
    isnothing(journal) && return staged_digest(specialized, modules)
    marked = "staged " * key
    marked in journal.crashed && return nothing
    record!(journal, start_record(marked, method_label(specialized.def::Method) * " generator", true))
    code = staged_digest(specialized, modules)
    record!(journal, finish_record(marked, nothing))
    return code
end

"""
`entry` that also reads package methods, generator instances and package names of inference behind compiler `edges`;
`nothing` when edges are unknown, walk gives none (`dependency_methods!`), or generator crashed (`staged_record`).
Offset inference of effects stage can read methods unit inference never reached. `memo` caches ids and digests.
"""
function with_edges!(memo::StoreMemo, entry::Entry, edges::Union{Nothing, AbstractVector{Any}}, files::AbstractDict{String, SyntaxFile}, journal::Union{Nothing, Journal})::Union{Nothing, Entry}
    isnothing(edges) && return nothing
    isempty(edges) && return entry
    read = dependency_methods!(memo, edges, files)
    isnothing(read) && return nothing
    found, generated, callees, types = read
    records = [staged_record(memo, specialized, journal) for specialized in generated]
    any(isnothing, records) && return nothing
    digests = unique!(append!(copy(entry.methods), method_digests!(memo, found)))
    names = sort!(unique!(append!(copy(entry.names), read_names(memo, callees, types))))
    return Entry(entry.file, digests, append!(copy(entry.staged), Staged[something(record) for record in records]), names, entry.inferred, entry.effects)
end

"""Serialized bytes of `data`, as store entry holds it."""
serialized(@nospecialize(data::Any))::Vector{UInt8} = (bytes = IOBuffer(); serialize(bytes, data); take!(bytes))

"""
Digest of serialized `data`: printed types depend on `Main` imports. Vector of `Any` compiles serializer once; tuple of
types would compile it once per tuple type.
"""
digest(@nospecialize(data::Any))::String = bytes2hex(sha256(sprint(serialize, Any[data])))

"""Leading 16 hex digits of `digest`: name meaning (`meanings`) only has to change when name changes."""
short(digest::String)::String = first(digest, 16)
