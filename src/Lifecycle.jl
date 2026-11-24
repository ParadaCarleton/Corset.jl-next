"""`lifecycle` stage (`lifecycle.md`): arrays of each package method, merged over array events of its units."""
module Lifecycle

using ..Facts: ArrayEvent, ArrayLife, ArrayPath, LifecycleFacts, MethodArrays, PackageFacts, Rebind
using ..Effects: UnitEffects

"""Merge key of array over units: allocation span bytes."""
array_key(array::ArrayLife)::Tuple{String, Int, Int} = (array.site.file, array.site.first_byte, array.site.last_byte)

"""Merge key of event over units: every field but path."""
event_key(event::ArrayEvent)::Tuple = (event.span, event.kind, event.coverage, event.indices, event.callee, event.view, event.order)

"""Rebind pair that every unit gives (`nothing` when one gives none); axes stay same only when they do in each."""
function merged_rebind(pairs::AbstractVector{Union{Nothing, Rebind}})::Union{Nothing, Rebind}
    any(isnothing, pairs) && return nothing
    earlier = unique(pair.earlier for pair in pairs)
    length(earlier) == 1 || return nothing
    return Rebind(only(earlier), all(pair -> pair.same_axes, pairs))
end

"""
One array from its facts in each unit of method: events of all units, each once with worst path; event that some unit
lacks is `branch` at best, since that unit skips it. Dimensions and rebind pair only when units agree.
"""
function merged_array(units::AbstractVector{ArrayLife})::ArrayLife
    events, present = Dict{Tuple, ArrayEvent}(), Dict{Tuple, BitSet}()
    for (position, unit) in enumerate(units), event in unit.events
        key = event_key(event)
        found = get(events, key, event)
        events[key] = Int(event.path) > Int(found.path) ? event : found
        push!(get!(BitSet, present, key), position)
    end
    for key in collect(keys(events))
        event = events[key]
        (length(present[key]) < length(units) && event.path == ArrayPath.sure) || continue
        events[key] = ArrayEvent(event.span, event.kind, event.coverage, event.indices, ArrayPath.branch, event.callee, event.view, event.order)
    end
    ordered = sort!(collect(values(events)); by = event -> (event.order, event.span.first_byte, event.span.last_byte, Int(event.kind)))
    dimensions = allequal(unit.dimensions for unit in units) ? first(units).dimensions : nothing
    return ArrayLife(first(units).site, first(units).kind, dimensions, ordered, merged_rebind(Union{Nothing, Rebind}[unit.rebind for unit in units]))
end

"""
`lifecycle` stage facts of `package` from effects records of its units with their methods, in inference order
(`Effects.effects_facts`). Units without verdict give no arrays.
"""
function lifecycle_facts(package::PackageFacts, records::AbstractVector{Pair{Method, Union{Nothing, UnitEffects}}})::LifecycleFacts
    found = IdDict{Method, Dict{Tuple{String, Int, Int}, Vector{ArrayLife}}}()
    for (method, record) in records
        (isnothing(record) || !record.verdict) && continue
        arrays = get!(Dict{Tuple{String, Int, Int}, Vector{ArrayLife}}, found, method)
        foreach(array -> push!(get!(Vector{ArrayLife}, arrays, array_key(array)), array), record.arrays)
    end
    methods = MethodArrays[]
    for site in package.methods
        arrays = get(found, site.method, nothing)
        (isnothing(arrays) || isempty(arrays)) && continue
        push!(methods, MethodArrays(site, ArrayLife[merged_array(arrays[key]) for key in sort!(collect(keys(arrays)))]))
    end
    return LifecycleFacts(methods)
end

end
