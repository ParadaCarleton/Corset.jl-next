"""Cache key of `instance`: digest of its method signature and specialization (`Inference.entry_key`)."""
instance_key!(run::Run, instance::Core.MethodInstance)::String = get!(() -> entry_key(instance.def::Method, instance.specTypes), run.cache.keys, instance)

"""Whether `instance` is package code by itself: its method lies in package, or its signature names package type."""
function package_instance!(run::Run, instance::Core.MethodInstance)::Bool
    method = instance.def
    return !(method isa Method) || method.module in run.modules || names_package!(run.cache.named, instance.specTypes, run.modules)
end

"""Whether `variant` is package code by itself (`package_instance!`), or constant of variant is package module."""
package_variant!(run::Run, variant::Variant)::Bool = package_instance!(run, first(variant)) || any(constant -> last(constant) in run.modules, last(variant))

"""
Whether `instance` is library instance (`effects.md`, Solve and cache): neither it nor any instance its native inference
edges reach is package code (`package_instance!`). New method of package that changes dispatch of library call removes
cached code of caller, so walk sees it. Instance without cached code takes edges of its inference in run; else it hides
its edges and counts as package. Search that finds none marks every instance it visited.
"""
function outside!(run::Run, instance::Core.MethodInstance)::Bool
    haskey(run.cache.outside, instance) && return run.cache.outside[instance]
    visited, pending = Base.IdSet{Core.MethodInstance}(), Any[instance]
    while !isempty(pending)
        found = edge_instance(pop!(pending))
        (isnothing(found) || found in visited) && continue
        known = get(run.cache.outside, found, nothing)
        known === true && continue
        push!(visited, found)
        code = CC.get(CC.code_cache(run.interpreter), found, nothing)
        edges = code isa Core.CodeInstance ? code.edges : get(run.cache.edges, found, nothing)
        (known === false || package_instance!(run, found) || isnothing(edges)) && return (run.cache.outside[instance] = false)
        append!(pending, edges)
    end
    foreach(found -> run.cache.outside[found] = true, visited)
    return true
end

"""Entry under `key` of library cache `entries` for library instance `instance` (`outside!`); `nothing` when cache holds none."""
(library_entry(run::Run, entries::Dict{K, V}, key::K, instance::Core.MethodInstance)::Union{Nothing, V}) where {K, V} = haskey(entries, key) && outside!(run, instance) ? entries[key] : nothing

"""Stored summary of library cache for `variant` (`library_entry`). Empty cache computes no key."""
stored_summary(run::Run, variant::Variant)::Union{Nothing, Summary} = isempty(run.cache.library.summaries) ? nothing : library_entry(run, run.cache.library.summaries, (instance_key!(run, first(variant)), last(variant)), first(variant))

"""Slot-name parameters of library cache for `instance` (`library_entry`)."""
stored_fields(run::Run, instance::Core.MethodInstance)::Union{Nothing, Set{Int}} = isempty(run.cache.library.fields) ? nothing : library_entry(run, run.cache.library.fields, instance_key!(run, instance), instance)

"""Whether stand-ins cut `instance`, as library cache holds (`library_entry`)."""
stored_cut(run::Run, instance::Core.MethodInstance)::Union{Nothing, Bool} = isempty(run.cache.library.cuts) ? nothing : library_entry(run, run.cache.library.cuts, instance_key!(run, instance), instance)

"""Whether stand-ins cut `instance` with native inference `frame`: library cache answer, else `stand_in_cut`."""
stored_or_cut(run::Run, instance::Core.MethodInstance, frame::CC.InferenceState)::Bool = (stored = stored_cut(run, instance); isnothing(stored) ? stand_in_cut(run, frame) : stored)

"""Whether `variant` of solved `run` is package code by itself (`package_reach`)."""
function package_solve!(run::Run, variant::Variant)::Bool
    package_variant!(run, variant) && return true
    return !haskey(run.codes, variant) && !outside!(run, first(variant))
end

"""
Variants of solved `run` whose solve reaches package code, itself included: call graph components, callees first, take
reach of their callees. Dispatch of run sees each package method, so variant with code needs own check only
(`package_variant!`). Hit, shortcut or blind spot ends solve in native code, so such variant needs `outside!` too; hit
passed it at lookup.
"""
function package_reach(run::Run)::Set{Variant}
    order = collect(keys(run.summaries))
    successors, inside = call_graph(run, order), falses(length(order))
    for component in components(successors)
        reaches = any(member -> package_solve!(run, order[member]) || any(callee -> inside[callee], successors[member]), component)
        inside[component] .= reaches
    end
    return Set(order[inside])
end

"""
New library cache entries of solved `run` (`effects.md`, Solve and cache): slot-name parameters, cuts and summaries of
library instances whose solve reached library instances only. Summary with callback records stays out: caller of hit
would need summaries of record variants too. Keys cache holds already stay out.
"""
function library_entries(run::Run)::Library
    inside, entries = package_reach(run), Library()
    for (variant, summary) in run.summaries
        (variant in inside || !isempty(summary.callbacks)) && continue
        # Hit keeps key of its entry, so it stays out too.
        key = (instance_key!(run, first(variant)), last(variant))
        haskey(run.cache.library.summaries, key) || (entries.summaries[key] = summary)
    end
    # Variant callees are callees of instance body, so library variant with code proves its instance.
    proven = Base.IdSet{Core.MethodInstance}(first(variant) for variant in keys(run.codes) if !(variant in inside))
    for (instance, fields) in run.fields
        instance in proven || continue
        key = instance_key!(run, instance)
        haskey(run.cache.library.fields, key) || (entries.fields[key] = fields)
    end
    for (instance, cut) in run.cuts
        outside!(run, instance) || continue
        key = instance_key!(run, instance)
        haskey(run.cache.library.cuts, key) || (entries.cuts[key] = cut)
    end
    return entries
end
