# Method store: compiler edges, package methods they reach, method and generator digests, store entries.

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
ones apart. Walk passes through package methods and through dependency specializations that name package type
(`map(f, xs)` with package `f`). `nothing` when generated instance has signature store cannot read back (`holds_gensym`).
`named` caches `names_package!` answers.
"""
function dependency_methods!(named::IdDict{Any, Bool}, edges::AbstractVector{Any}, files::AbstractDict{String, SyntaxFile}, modules::AbstractSet{Module})::Union{Nothing, Tuple{Vector{Method}, Vector{Core.MethodInstance}}}
    found, staged, visited, stack = Method[], Core.MethodInstance[], Base.IdSet{Core.MethodInstance}(), append!(Any[], edges)
    while !isempty(stack)
        edge = pop!(stack)
        instance = edge_instance(edge)
        (isnothing(instance) || instance in visited) && continue
        push!(visited, instance)
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
            names_package!(named, instance.specTypes, modules) || continue
        end
        append!(stack, edges_of(edge))
    end
    return found, staged
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
Digest of lowered code of `method` as package load left it, macro output and `@eval` code included. Closure renamed by
edit has other code, so digest also checks what closure name means.
"""
code_digest(method::Method)::String = digest(Base.uncompressed_ast(method))

"""Digest of code generator of `@generated` method gives for `instance`; `nothing` digests too when generator throws."""
staged_digest(instance::Core.MethodInstance)::String = digest(CC.get_staged(instance, Base.get_world_counter()))

"""Methods defined in analyzed `files` by `method_id`, keyword bodies and closures included; `ids` keeps each one's id."""
function method_index(files::AbstractDict{String, SyntaxFile})::Tuple{Dict{String, Method}, IdDict{Method, String}}
    ids = IdDict{Method, String}()
    Base.visit(method -> haskey(files, string(method.file)) && (ids[method] = method_id(method)), Core.methodtable)
    return Dict(id => method for (method, id) in ids), ids
end

# corset: allow bang-convention -- memo of code digests; result never changes
"""
Entry `store` holds under `key` when file of method keeps its hash in `hashes`, each method entry read keeps its code,
and each generator it read gives same code. `index` finds methods by id; `codes` caches digests by id or staged key.
Generator runs under crash `journal` (`journaled_digest`).
"""
function valid_entry(store::Store, key::String, hashes::AbstractDict{String, String}, index::AbstractDict{String, Method}, codes::AbstractDict{String, String}, journal::Union{Nothing, Journal})::Union{Nothing, Entry}
    entry = get(store, key, nothing)
    (isnothing(entry) || get(hashes, first(entry.file), "") != last(entry.file)) && return nothing
    for (id, code) in entry.methods
        method = get(index, id, nothing)
        (isnothing(method) || get!(() -> code_digest(method), codes, id) != code) && return nothing
    end
    for staged in entry.staged
        method = get(index, staged.method, nothing)
        isnothing(method) && return nothing
        specialized = instance(method, deserialize(IOBuffer(staged.signature))::Type)
        isnothing(specialized) && return nothing
        code = cached_digest(codes, journal, specialized, staged.key)
        (isnothing(code) || code != staged.code) && return nothing
    end
    return entry
end

"""
Store entry of `inferred` result of `site` on `signature`, whose inferences gave compiler `edges`; `nothing` when walk
gives none (`dependency_methods!`). `ids` and `codes` cache method ids and digests.
"""
function entry!(named::IdDict{Any, Bool}, ids::IdDict{Method, String}, codes::AbstractDict{String, String}, site::MethodSite, signature::Type, inferred::Inferred, edges::AbstractVector{Any}, files::AbstractDict{String, SyntaxFile}, hashes::AbstractDict{String, String}, modules::AbstractSet{Module})::Union{Nothing, Entry}
    read = dependency_methods!(named, edges, files, modules)
    isnothing(read) && return nothing
    found, generated = read
    if Base.hasgenerator(site.method)
        holds_gensym(signature) && return nothing
        push!(generated, something(instance(site.method, signature)))
    else
        push!(found, site.method)
    end
    # Unit start record of crash journal covers generators that run here.
    digests, records = method_digests(ids, codes, found), Staged[something(staged_record(ids, codes, specialized, nothing)) for specialized in generated]
    return Entry(site.file.path => hashes[site.file.path], digests, records, serialized(inferred), UInt8[])
end

"""Digest of each method in `found` by id, once per id; `ids` and `codes` cache ids and digests."""
function method_digests(ids::IdDict{Method, String}, codes::AbstractDict{String, String}, found::AbstractVector{Method})::Vector{Pair{String, String}}
    methods = Dict(get!(() -> method_id(method), ids, method) => method for method in found)
    return [id => get!(() -> code_digest(method), codes, id) for (id, method) in methods]
end

# corset: allow bang-convention -- memo of method ids and digests; crash journal records progress
"""
Store record of generator instance `specialized`; `ids` and `codes` cache method ids and digests. Generator runs under
crash `journal` (`journaled_digest`); `nothing` when earlier run crashed there.
"""
function staged_record(ids::IdDict{Method, String}, codes::AbstractDict{String, String}, specialized::Core.MethodInstance, journal::Union{Nothing, Journal})::Union{Nothing, Staged}
    method, key = specialized.def::Method, entry_key(specialized.def::Method, specialized.specTypes)
    code = cached_digest(codes, journal, specialized, key)
    isnothing(code) && return nothing
    return Staged(get!(() -> method_id(method), ids, method), serialized(specialized.specTypes), key, code)
end

# corset: allow bang-convention -- memo of code digests; crash journal records progress
"""`journaled_digest` of `specialized` that `codes` keeps under staged `key`; crashed key keeps none."""
function cached_digest(codes::AbstractDict{String, String}, journal::Union{Nothing, Journal}, specialized::Core.MethodInstance, key::String)::Union{Nothing, String}
    haskey(codes, key) && return codes[key]
    code = journaled_digest(journal, specialized, key)
    isnothing(code) || (codes[key] = code)
    return code
end

# corset: allow bang-convention -- crash journal records progress; caller reads it only after crash
"""
`staged_digest` of `specialized` between start and finish records of `"staged "` plus staged `key` in crash `journal`:
generator can abort process. `nothing` when earlier run crashed there.
"""
function journaled_digest(journal::Union{Nothing, Journal}, specialized::Core.MethodInstance, key::String)::Union{Nothing, String}
    isnothing(journal) && return staged_digest(specialized)
    marked = "staged " * key
    marked in journal.crashed && return nothing
    record!(journal, start_record(marked, method_label(specialized.def::Method) * " generator", true))
    code = staged_digest(specialized)
    record!(journal, finish_record(marked, nothing))
    return code
end

"""
`entry` that also reads package methods and generator instances of inference behind compiler `edges`; `nothing` when
edges are unknown, walk gives none (`dependency_methods!`), or generator crashed (`staged_record`). Offset inference of
effects stage can read methods unit inference never reached.
"""
function with_edges(entry::Entry, edges::Union{Nothing, AbstractVector{Any}}, files::AbstractDict{String, SyntaxFile}, modules::AbstractSet{Module}, journal::Union{Nothing, Journal})::Union{Nothing, Entry}
    isnothing(edges) && return nothing
    isempty(edges) && return entry
    read = dependency_methods!(IdDict{Any, Bool}(), edges, files, modules)
    isnothing(read) && return nothing
    (found, generated), ids, codes = read, IdDict{Method, String}(), Dict{String, String}()
    records = [staged_record(ids, codes, specialized, journal) for specialized in generated]
    any(isnothing, records) && return nothing
    digests = unique!(append!(copy(entry.methods), method_digests(ids, codes, found)))
    return Entry(entry.file, digests, append!(copy(entry.staged), Staged[something(record) for record in records]), entry.inferred, entry.effects)
end

"""Serialized bytes of `data`, as store entry holds it."""
serialized(@nospecialize(data::Any))::Vector{UInt8} = (bytes = IOBuffer(); serialize(bytes, data); take!(bytes))

"""
Digest of serialized `data`: printed types depend on `Main` imports. Vector of `Any` compiles serializer once; tuple of
types would compile it once per tuple type.
"""
digest(@nospecialize(data::Any))::String = bytes2hex(sha256(sprint(serialize, Any[data])))
