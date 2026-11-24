"""
`slice-copy` (F40): slice copies elements that method only reads.

## Description
Reports slice (`A[:, j]`, `x[2:end]`, `x[indices]`) of package method that method only reads: no write, resize,
escape or `φ` join, and no read in loop that slice lies outside. Allocations and their events come from `lifecycle`
stage.

## Rationale
Index with range, array or `:` copies selected elements into new array. Read-only use needs no copy: view reads same
elements in place, without allocation.

## Example
```julia
column_total(A::Matrix{Float64}, j::Int) = sum(A[:, j])
```

## Alternative
```julia
column_total(A::Matrix{Float64}, j::Int) = sum(@view(A[:, j]))
```

## Limitations
Fix is `likely`: view aliases parent, so write to parent between slice and read changes result, and callee that
requires `Array` rejects view. Slice that inference cannot place gets `manual` fix. Slice that loop reads many times passes:
contiguous copy can read faster than strided view.
"""
module SliceCopy

using ...Facts

const NAME = Symbol("slice-copy")

"""Event kinds after which view can differ from copy, or uses stay unseen."""
const CHANGES = (ArrayEventKind.write, ArrayEventKind.resize, ArrayEventKind.escape, ArrayEventKind.joined)

"""Whether `array` is slice that method only reads, outside loops that repeat reads."""
function read_only(array::ArrayLife)::Bool
    array.kind == AllocationKind.slice || return false
    any(event -> event.kind in CHANGES || event.path == ArrayPath.loop, array.events) && return false
    return any(event -> event.kind == ArrayEventKind.read, array.events)
end

"""
Fix that wraps slice at `site` in `@view(…)`: `likely`. `manual` when `site` is no indexing node of `files`: statement
span stands in for slice that inference cannot place.
"""
function view_fix(files::AbstractDict{String, SyntaxFile}, site::Span)::Fix
    text = "wrap slice in `@view(…)`: view reads same elements without copy"
    file = get(files, site.file, nothing)
    (!isnothing(file) && any(node -> span(file, node) == site, forms(file, "ref"))) || return manual_fix(text)
    before = Span(site.file, site.first_byte, site.first_byte - 1, Precision.exact)
    after = Span(site.file, site.last_byte + 1, site.last_byte, Precision.exact)
    return Fix(text, [Edit(before, "@view("), Edit(after, ")")], Tier.likely)
end

"""Findings for each slice of package method that method only reads."""
function findings(facts::FactSet)::Vector{Finding}
    lifecycle = facts.lifecycle
    isnothing(lifecycle) && return Finding[]
    files, found = Dict(file.path => file for file in facts.files), Finding[]
    for method in lifecycle.methods, array in method.arrays
        read_only(array) || continue
        read = first(event for event in array.events if event.kind == ArrayEventKind.read)
        push!(
            found, Finding(
                NAME, :slice_copy, Confidence.definite, "slice copies elements that method only reads",
                Label(array.site, "copies elements here"), [Label(read.span, "only reads copy")],
                "copy allocates new array; view reads same elements in place", view_fix(files, array.site),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.performance, [40], Stage.lifecycle, findings)

end
