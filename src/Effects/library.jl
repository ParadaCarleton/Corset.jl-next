"""
Instance key of `instance`: canonical texts of its method signature and specialization (`type_text!`). Library cache lists
instance key of each entry, so lookup walks closure of listed instance only (`listed`).
"""
instance_key!(run::Run, instance::Core.MethodInstance)::String =
    get!(() -> "$(first(type_text!(run, (instance.def::Method).sig))) $(first(type_text!(run, instance.specTypes)))", run.cache.keys, instance)

"""Whether `instance` is package code by itself: its method lies in package, or its signature names package type."""
function package_instance!(run::Run, instance::Core.MethodInstance)::Bool
    method = instance.def
    return !(method isa Method) || method.module in run.modules || names_package!(run.cache.named, instance.specTypes, run.modules)
end

"""Whether `variant` is package code by itself (`package_instance!`), or constant of variant is package module."""
package_variant!(run::Run, variant::Variant)::Bool = package_instance!(run, first(variant)) || any(constant -> last(constant) in run.modules, last(variant))

"""Whether `list` holds `item` itself (`===`)."""
function identical_in(@nospecialize(item::Any), list::Vector{Any})::Bool
    for known in list
        known === item && return true
    end
    return false
end

"""
Throw helper verdict on `callee` (`throw_helper`), once per run. Records that `instance` read it: library cache entry
keeps verdicts its closure read, and hits only while each holds (`stored_value!`).
"""
function helper!(run::Run, instance::Core.MethodInstance, @nospecialize(callee::Any))::Bool
    read = get!(Vector{Any}, run.cache.helpers, instance)
    # Closures over `callee` would compile `any` and `get!` once per callee type.
    identical_in(callee, read) || push!(read, callee)
    verdict = get(run.helpers, callee, nothing)
    isnothing(verdict) && (verdict = run.helpers[callee] = throw_helper(callee))
    return first(verdict)
end

"""
Node of `instance` in native edge graph: its cached code instance, else `instance` when run inferred it (`inferred!`);
else `nothing`, since edges are unknown.
"""
function instance_node(run::Run, instance::Core.MethodInstance)::Any
    code = CC.get(CC.code_cache(run.interpreter), instance, nothing)
    code isa Core.CodeInstance && return code
    return haskey(run.cache.edges, instance) ? instance : nothing
end

"""Native inference edges of `node` (`instance_node`, or code instance that edge names)."""
node_edges(run::Run, @nospecialize(node::Any))::Union{Core.SimpleVector, Vector{Any}} = node isa Core.CodeInstance ? node.edges : run.cache.edges[node::Core.MethodInstance]

"""
Canonical text of `type` inside type variables `bound` (innermost last); adds root modules it names to `modules`. Type counts
by module path, name and parameters; union by members; variable of `bound` by binding depth, so renamed variables agree.
Composite text is digest of its parts (`Cache.digest`); part without free variable takes its run text (`typed!`).
"""
function structure_text!(run::Run, @nospecialize(type::Any), bound::Vector{TypeVar}, modules::Vector{Module})::String
    part(@nospecialize(inner::Any))::String = Base.has_free_typevars(inner) ? structure_text!(run, inner, bound, modules) : typed!(run, inner, modules)
    parts = if type isa TypeVar
        depth = findlast(variable -> variable === type, bound)
        isnothing(depth) || return "bound $(length(bound) - something(depth))"
        String["free", string(type.name), part(type.lb), part(type.ub)]
    elseif type isa Union
        String["union", part(type.a), part(type.b)]
    elseif type isa UnionAll
        lower, upper = part(type.var.lb), part(type.var.ub)
        push!(bound, type.var)
        body = part(type.body)
        pop!(bound)
        String["where", lower, upper, body]
    elseif type isa Core.TypeofVararg
        String["vararg", isdefined(type, :T) ? part(type.T) : "", isdefined(type, :N) ? part(type.N) : ""]
    elseif type isa DataType
        push!(modules, Base.moduleroot(type.name.module))
        String["type", join(fullname(type.name.module), '.'), string(type.name.name), String[part(type.parameters[index]) for index in 1:length(type.parameters)]...]
    elseif type isa Module
        push!(modules, Base.moduleroot(type))
        return "module " * join(fullname(type), '.')
    elseif type isa Union{Int, Symbol, Bool}
        return "$(typeof(type)) $type"
    elseif type isa Tuple
        # Loop: closure over tuple value would compile once per tuple type.
        items = String["tuple"]
        for index in 1:nfields(type)
            push!(items, part(getfield(type, index)))
        end
        items
    else
        # Other value parameter (`Val{1.0}`): serializer writes its bytes.
        String["value", part(typeof(type)), Inference.digest(type)]
    end
    return Cache.digest(parts, String[])
end

"""Canonical text of `type` (`structure_text!`) and root modules it names, once per run."""
function type_text!(run::Run, @nospecialize(type::Any))::Tuple{String, Vector{Module}}
    haskey(run.cache.types, type) && return run.cache.types[type]
    modules = Module[]
    text = structure_text!(run, type, TypeVar[], modules)
    return run.cache.types[type] = (text, unique!(modules))
end

"""Canonical text of `type` (`type_text!`); adds root modules it names to `modules`."""
function typed!(run::Run, @nospecialize(type::Any), modules::Vector{Module})::String
    text, named = type_text!(run, type)
    append!(modules, named)
    return text
end

"""
Digest of owner texts of root module `root` (`Cache.owner_texts!`), once per run; empty for module without texts, such
as Base. `nothing` for package module or module without owner text.
"""
function owner_digest!(run::Run, root::Module)::Union{Nothing, String}
    haskey(run.cache.owned, root) && return run.cache.owned[root]
    texts = root in run.modules ? nothing : Cache.owner_texts!(run.cache.owners, root, DEPOT_PATH)
    return run.cache.owned[root] = isnothing(texts) ? nothing : isempty(texts) ? "" : Cache.digest(texts, String[])
end

"""
Owner digests of root `modules` (`owner_digest!`), sorted, empty ones left out; `nothing` when one has none. Library
summary depends on code of each module its closure names.
"""
function owners!(run::Run, modules::Vector{Module})::Union{Nothing, Vector{String}}
    found = String[]
    for mod in unique!(modules)
        owned = owner_digest!(run, mod)
        isnothing(owned) && return nothing
        isempty(owned) || push!(found, owned)
    end
    return sort!(found)
end

"""
Text of edge `target`, and its node added to `successors`: instance key of code or method instance, ABI type when code
overrides it, or module and signature of method that inference gave no code. Adds modules it names to `modules`.
`nothing` when instance has no node (`instance_node`) or target has other form.
"""
function edge_text!(run::Run, @nospecialize(target::Any), modules::Vector{Module}, successors::Vector{Any})::Union{Nothing, String}
    if target isa Method
        push!(modules, Base.moduleroot(target.module))
        return "method $(join(fullname(target.module), '.')) $(typed!(run, target.sig, modules))"
    end
    instance = edge_instance(target)
    isnothing(instance) && return nothing
    node = target isa Core.CodeInstance ? target : instance_node(run, instance)
    isnothing(node) && return nothing
    push!(successors, node)
    override = target isa Core.CodeInstance ? target.def : target
    abi = override isa Core.ABIOverride ? " abi " * typed!(run, override.abi, modules) : ""
    return "instance " * instance_key!(run, instance) * abi
end

"""
Canonical text of native edge record at `position` of `edges`, and position after record. Julia 1.13 forms: lookup
(match count, negative when matches do not cover call; call type; matches), single covering match, binding, call type
with method table (lookup without covering match), call type with target (`invoke` or inlining). Too many matches
leave no record. Adds modules record names to `modules` and edge nodes to `successors`; `nothing` for other form.
"""
function record_text!(run::Run, edges::Union{Core.SimpleVector, Vector{Any}}, position::Int, modules::Vector{Module}, successors::Vector{Any})::Union{Nothing, Tuple{String, Int}}
    item = edges[position]
    if item isa Int
        last_target = position + 1 + abs(item)
        parts = ["lookup $item", typed!(run, edges[position + 1], modules)]
        for index in (position + 2):last_target
            text = edge_text!(run, edges[index], modules, successors)
            isnothing(text) && return nothing
            push!(parts, text)
        end
        return join(parts, ' '), last_target + 1
    elseif item isa Union{Core.CodeInstance, Core.MethodInstance, Method}
        text = edge_text!(run, item, modules, successors)
        return isnothing(text) ? nothing : ("call " * text, position + 1)
    elseif item isa Core.Binding
        reference = item.globalref
        push!(modules, Base.moduleroot(reference.mod))
        return "binding $(join(fullname(reference.mod), '.')) $(reference.name)", position + 1
    elseif item isa Type && position < length(edges)
        target = edges[position + 1]
        text = target === Core.methodtable ? "table" : edge_text!(run, target, modules, successors)
        return isnothing(text) ? nothing : ("$text $(typed!(run, item, modules))", position + 2)
    end
    return nothing
end

"""
Own text of `node` for closure key, and its successor nodes: instance key, canonical text of each native edge record
(`record_text!`), sorted, and owner texts of modules that instance and records name (`owners!`). `nothing` when
instance is package code, or for record, edge or module without text. Run keeps text it found: nodes and their edges
stay fixed, while edge target without node can gain one.
"""
function node_text!(run::Run, @nospecialize(node::Any))::Union{Nothing, Tuple{String, Vector{Any}}}
    haskey(run.cache.texts, node) && return run.cache.texts[node]
    instance = edge_instance(node)::Core.MethodInstance
    package_instance!(run, instance) && return nothing
    method = instance.def::Method
    modules, successors, records = Module[Base.moduleroot(method.module)], Any[], String[]
    typed!(run, method.sig, modules)
    typed!(run, instance.specTypes, modules)
    head = edge_text!(run, node, modules, Any[])
    edges, position = node_edges(run, node), 1
    while position <= length(edges)
        found = record_text!(run, edges, position, modules, successors)
        isnothing(found) && return nothing
        push!(records, first(found))
        position = last(found)
    end
    owners = owners!(run, modules)
    isnothing(owners) && return nothing
    return run.cache.texts[node] = (join([something(head); sort!(unique!(records)); owners], '\n'), successors)
end

"""Add `callees` missing from `found` by identity."""
function add_callees!(found::Vector{Any}, callees::Vector{Any})::Nothing
    for callee in callees
        any(known -> known === callee, found) || push!(found, callee)
    end
    return nothing
end

"""
Pop component of `node` from `stack` (`walk_components!`). Each member gets key: digest of member texts (`texts`) and of
keys of components members reach; `nothing` when one of them has none, or when `state` rejects member. Members share
helper callees their closure read.
"""
function finish_component!(run::Run, state::Closure, texts::IdDict{Any, Union{Nothing, Tuple{String, Vector{Any}}}}, stack::Vector{Any}, open::Base.IdSet{Any}, @nospecialize(node::Any))::Nothing
    members = Any[]
    while isempty(members) || last(members) !== node
        member = pop!(stack)
        delete!(open, member)
        push!(members, member)
    end
    inside, parts, reached, helpers, valid = Base.IdSet{Any}(members), String[], String[], Any[], true
    for member in members
        found = texts[member]
        (isnothing(found) || edge_instance(member) in state.rejected) && (valid = false; continue)
        push!(parts, first(found))
        add_callees!(helpers, get(run.cache.helpers, edge_instance(member), Any[]))
        for child in last(found)
            child in inside && continue
            key = state.keys[child]
            if isnothing(key)
                valid = false
            else
                push!(reached, key)
            end
            add_callees!(helpers, state.helpers[child])
        end
    end
    # Count separates member texts from reached keys.
    key = valid ? Cache.digest([string(length(parts)); sort!(parts); sort!(unique!(reached))], String[]) : nothing
    for member in members
        state.keys[member], state.helpers[member] = key, helpers
    end
    return nothing
end

"""
Key of each component of native edge graph that `root` reaches and no earlier walk keyed (`closure_key!`), callees
first: Tarjan's algorithm with explicit stack, so deep edge chains need no deep recursion.
"""
function walk_components!(run::Run, state::Closure, @nospecialize(root::Any))::Nothing
    index, low, texts = IdDict{Any, Int}(), IdDict{Any, Int}(), IdDict{Any, Union{Nothing, Tuple{String, Vector{Any}}}}()
    stack, open, work, count = Any[], Base.IdSet{Any}(), Tuple{Any, Int}[(root, 0)], 0
    while !isempty(work)
        node, visited = work[end]
        if visited == 0
            count += 1
            index[node] = low[node] = count
            push!(stack, node)
            push!(open, node)
            texts[node] = node_text!(run, node)
        end
        found = texts[node]
        successors = isnothing(found) ? Any[] : last(found)
        if visited < length(successors)
            work[end] = (node, visited + 1)
            child = successors[visited + 1]
            if haskey(index, child)
                child in open && (low[node] = min(low[node], index[child]))
            elseif !haskey(state.keys, child)
                push!(work, (child, 0))
            end
            continue
        end
        pop!(work)
        isempty(work) || (low[first(work[end])] = min(low[first(work[end])], low[node]))
        low[node] == index[node] && finish_component!(run, state, texts, stack, open, node)
    end
    return nothing
end

"""
Closure key of `instance` (`effects.md`, Solve and cache): digest of its instance key, key of component of its node in
native edge graph, and alias methods outside Core (`alias_text`). Component key digests own texts of members
(`node_text!`) and keys of components they reach, so key depends on closure alone, whatever walk reaches node first.
`nothing` for package instance, instance without node, or closure with node without text.
"""
function closure_key!(run::Run, state::Closure, instance::Core.MethodInstance)::Union{Nothing, String}
    package_instance!(run, instance) && return nothing
    root = instance_node(run, instance)
    isnothing(root) && return nothing
    haskey(state.keys, root) || walk_components!(run, state, root)
    reached = state.keys[root]
    return isnothing(reached) ? nothing : Cache.digest([instance_key!(run, instance), something(reached), run.cache.aliases], String[])
end

"""
Entry key of summary of `variant` (`Library`): closure key of its instance (`closure_key!`), constants by position and
canonical text (`structure_text!`), and owner texts of module constants (`owners!`). `nothing` without closure key, or
with module constant of package or without owner.
"""
function variant_key!(run::Run, state::Closure, variant::Variant)::Union{Nothing, String}
    closure = closure_key!(run, state, first(variant))
    isnothing(closure) && return nothing
    modules, constants = Module[], String[]
    for (position, constant) in last(variant)
        push!(constants, "$position " * structure_text!(run, constant::VariantConstant, TypeVar[], modules))
    end
    owners = owners!(run, modules)
    isnothing(owners) && return nothing
    # Count separates constants from owner texts.
    return Cache.digest(["summary", something(closure), string(length(constants)), constants..., owners...], String[])
end

"""Entry key of `kind` (`parameters` or `cut`) of `instance` (`Library`): its closure key; `nothing` without one."""
function instance_entry_key!(run::Run, state::Closure, kind::String, instance::Core.MethodInstance)::Union{Nothing, String}
    closure = closure_key!(run, state, instance)
    return isnothing(closure) ? nothing : Cache.digest([kind, something(closure)], String[])
end

"""
Value of type `T` that library cache holds under entry `key`, which `instance` reads; `nothing` when cache holds none, or
when throw helper verdict entry keeps no longer holds (`helper!`). Hit joins `run.cache.hits`.
"""
function stored_value!(run::Run, ::Type{T}, key::Union{Nothing, String}, instance::Core.MethodInstance)::Union{Nothing, T} where {T}
    stamped = isnothing(key) ? nothing : get(run.cache.library.entries, key, nothing)
    isnothing(stamped) && return nothing
    entry = deserialize(IOBuffer(stamped.bytes))::LibraryEntry
    for (callee, verdict) in entry.helpers
        helper!(run, instance, callee) == verdict || return nothing
    end
    push!(run.cache.hits, something(key))
    return entry.value::T
end

"""Whether library cache lists instance key of `instance` (`instance_key!`): only then can entry key of it match."""
listed(run::Run, instance::Core.MethodInstance)::Bool = !isempty(run.cache.library) && !package_instance!(run, instance) && instance_key!(run, instance) in run.cache.library.instances

"""Stored summary of library cache for `variant` (`stored_value!`)."""
stored_summary(run::Run, variant::Variant)::Union{Nothing, Summary} = listed(run, first(variant)) ? stored_value!(run, Summary, variant_key!(run, run.cache.closure, variant), first(variant)) : nothing

"""Variant parameters of library cache for `instance` (`stored_value!`)."""
stored_parameters(run::Run, instance::Core.MethodInstance)::Union{Nothing, Set{Int}} = listed(run, instance) ? stored_value!(run, Set{Int}, instance_entry_key!(run, run.cache.closure, "parameters", instance), instance) : nothing

"""Whether stand-ins cut `instance`, as library cache holds (`stored_value!`)."""
stored_cut(run::Run, instance::Core.MethodInstance)::Union{Nothing, Bool} = listed(run, instance) ? stored_value!(run, Bool, instance_entry_key!(run, run.cache.closure, "cut", instance), instance) : nothing

"""Whether stand-ins cut `instance` with native inference `frame`: library cache answer, else `stand_in_cut`."""
stored_or_cut(run::Run, instance::Core.MethodInstance, frame::CC.InferenceState)::Bool = (stored = stored_cut(run, instance); isnothing(stored) ? stand_in_cut(run, frame) : stored)

"""
Whether `instance` is Core method of alias function: inference reads `x !== y` as `x === y` and `x >: y` as `y <: x`,
and records no native edge. Julia version fixes its code; closure key holds other methods of both (`alias_text`).
"""
aliased(instance::Core.MethodInstance)::Bool = (method = instance.def::Method; method.module === Core && method.name in (:!==, :>:))

"""Text of methods of alias functions outside Core (`aliased`): method that takes dispatch from Core changes summary."""
function alias_text()::String
    found = String[]
    for alias in (Core.:!==, Core.:>:), method in methods(alias)
        method.module === Core || push!(found, "$(join(fullname(method.module), '.')) $(Inference.digest(method.sig))")
    end
    return join(sort!(found), '\n')
end

"""Whether every instance in `instances` lies in `targets` or is Core method of alias function (`aliased`)."""
function all_in(instances::Vector{Core.MethodInstance}, targets::Base.IdSet{Core.MethodInstance})::Bool
    for instance in instances
        instance in targets || aliased(instance) || return false
    end
    return true
end

"""Whether call `outcome` reaches `targets` only: dispatch to them, or no dispatch. Call without method counts out."""
function outcome_contained(outcome::Outcome.Type, targets::Base.IdSet{Core.MethodInstance})::Bool
    return @match outcome begin
        Outcome.Dispatch(instances, _) => all_in(instances, targets)
        Outcome.Dead() => false
        _ => true
    end
end

"""
Whether each call of `body` of `instance` reaches edge instances of its node only (`outcome_contained`). Union call
type that native inference splits, `!==` that inference folds, or callee limit (`limit_callee`), reach instance outside
native edges: closure key does not hold its inference.
"""
function contained(run::Run, instance::Core.MethodInstance, body::Body)::Bool
    node = instance_node(run, instance)
    isnothing(node) && return false
    targets = Base.IdSet{Core.MethodInstance}()
    for edge in node_edges(run, node)
        found = edge_instance(edge)
        isnothing(found) || push!(targets, found)
    end
    for outcome in body.outcomes
        isnothing(outcome) || outcome_contained(something(outcome), targets) || return false
    end
    return true
end

"""
Whether library cache cannot share `variant` of solved `run` by itself (`unshared`): package variant
(`package_variant!`), variant with body that calls outside native edges (`contained`, once per instance in
`checked`), or variant without code (hit, shortcut, blind spot) without closure key in `state`. Core method of alias
function counts as shared (`aliased`).
"""
function unshared!(run::Run, state::Closure, checked::IdDict{Core.MethodInstance, Bool}, variant::Variant)::Bool
    package_variant!(run, variant) && return true
    instance = first(variant)
    aliased(instance) && return false
    haskey(run.codes, variant) || return isnothing(closure_key!(run, state, instance))
    return !get!(() -> contained(run, instance, run.bodies[instance]::Body), checked, instance)
end

"""
Variants of solved `run` that library cache cannot share, as their solve reaches unshared variant (`unshared!`), itself
included: call graph components, callees first, take reach of their callees. Dispatch of run sees each package method,
so variant with code needs own check only. Closure key in `state` holds native edges, so solve that leaves them stays
out too.
"""
function unshared(run::Run, state::Closure)::Set{Variant}
    order, checked = collect(keys(run.summaries)), IdDict{Core.MethodInstance, Bool}()
    successors, inside = call_graph(run, order), falses(length(order))
    for component in components(successors)
        reaches = any(member -> unshared!(run, state, checked, order[member]) || any(callee -> inside[callee], successors[member]), component)
        inside[component] .= reaches
    end
    return Set(order[inside])
end

"""
Add `value` of `instance` under entry `key` to library cache `entries`, with throw helper verdicts its closure read in
`state`. Missing key, or key cache holds already, adds nothing.
"""
function add_entry!(entries::Library, run::Run, state::Closure, key::Union{Nothing, String}, instance::Core.MethodInstance, value::Union{Summary, Set{Int}, Bool})::Nothing
    (isnothing(key) || haskey(run.cache.library.entries, something(key))) && return nothing
    helpers = Pair{Any, Bool}[callee => first(run.helpers[callee]) for callee in state.helpers[instance_node(run, instance)]]
    listing = instance_key!(run, instance)
    entries.entries[something(key)] = Cache.Stamped(listing, serialized(LibraryEntry(value, helpers)), time())
    push!(entries.instances, listing)
    return nothing
end

"""
New library cache entries of solved `run` (`effects.md`, Solve and cache): summaries, variant parameters and cuts of
library instances, under keys of store phase. Store phase `Closure` rejects instances whose cut check inferred model
types (`stand_in_cut`): that inference reads methods outside native edges. Summary of variant that cache cannot share
(`unshared`), or with callback record, stays out: caller of hit would need summaries of record variants too. Library
variant with code proves variant parameters of its instance with body, since its callees are callees of that body.
"""
function library_entries(run::Run)::Library
    state = Closure(copy(run.cache.modeled))
    inside, entries = unshared(run, state), Library()
    for (variant, summary) in run.summaries
        (variant in inside || !isempty(summary.callbacks)) && continue
        add_entry!(entries, run, state, variant_key!(run, state, variant), first(variant), summary)
    end
    proven = Base.IdSet{Core.MethodInstance}(first(variant) for variant in keys(run.codes) if !(variant in inside))
    for (instance, parameters) in run.parameters
        # Shortcut or blind spot calls nothing, so its parameters need no proof.
        get(run.bodies, instance, nothing) isa Body && !(instance in proven) && continue
        add_entry!(entries, run, state, instance_entry_key!(run, state, "parameters", instance), instance, parameters)
    end
    for (instance, cut) in run.cuts
        add_entry!(entries, run, state, instance_entry_key!(run, state, "cut", instance), instance, cut)
    end
    return entries
end
