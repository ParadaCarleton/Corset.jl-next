"""
`unwritten-element` (F33, F34): method reads element of `undef` array before it writes it, or reads `zeros`-like
array whole after it writes part.

## Description
Kind `undef_read` (F33): first read of `similar` or `undef` array element that no earlier write covers. Finding is
`definite` when read is `sure` and only `sure` writes come before it. Read that path can skip, and `branch`, `loop`,
`unknown` or view write that can cover it, give `possible`. `sort!(a)` and like calls read before they write.
Kind `placeholder` (F34): filled array of constant size; `sure` element writes cover part of it, then method reads it
whole. Finding is `possible`: fill value can be data (`e = zeros(n); e[1] = 1.0` builds basis vector).
Allocations and their events come from `lifecycle` stage.

## Rationale
`undef` element holds whatever memory held before: bits element reads garbage, other element throws `UndefRefError`.
Fill value in element that code meant to write looks like data and gives wrong result without error.

## Example
```julia
function doubled(x::Vector{Float64})
    y = similar(x)
    y[1] = 2x[1]
    return sum(y)
end
```

## Alternative
```julia
doubled(x::Vector{Float64}) = sum(2 .* x)
```

## Limitations
Escape, resize or `φ` join of array ends check: later uses stay unseen. Loop that writes elements other than every
index (no fill loop) gives `possible`.
"""
module UnwrittenElement

using ...Facts

const NAME = Symbol("unwritten-element")

"""Event kinds after which uses of array stay unseen."""
const UNSEEN = (ArrayEventKind.escape, ArrayEventKind.resize, ArrayEventKind.joined)

"""Whether element writes `elements` cover every element of vector with constant `dimensions` (`nothing`: unknown)."""
every_element(elements::AbstractSet{<:AbstractVector{<:Integer}}, dimensions::Union{Nothing, AbstractVector{<:Integer}})::Bool =
    !isnothing(dimensions) && length(dimensions) == 1 && all(index -> [index] in elements, 1:only(dimensions))

"""
First read of `undef` `array` that no earlier write covers, with confidence; `nothing` when none. Only `sure` direct
write covers; other write, or write in loop that can run before read of later iteration, makes finding `possible`.
"""
function unwritten_read(array::ArrayLife)::Union{Nothing, Tuple{ArrayEvent, Confidence.T}}
    array.kind == AllocationKind.undef || return nothing
    whole, elements = false, Set{Vector{Int}}()
    doubtful = any(event -> event.kind == ArrayEventKind.write && event.path == ArrayPath.loop, array.events)
    for event in array.events
        event.kind in UNSEEN && return nothing
        if event.kind == ArrayEventKind.write
            sure = event.path == ArrayPath.sure && !event.view && event.coverage != Coverage.unknown
            doubtful |= !sure
            sure && event.coverage == Coverage.whole && (whole = true)
            sure && event.coverage == Coverage.element && push!(elements, event.indices)
            continue
        end
        (event.kind == ArrayEventKind.read && !whole) || continue
        event.coverage == Coverage.element && event.indices in elements && continue
        event.coverage == Coverage.whole && every_element(elements, array.dimensions) && continue
        # Read that path can skip, or read of unknown element after element writes, can miss unset element.
        unsure = doubtful || event.path != ArrayPath.sure || (event.coverage == Coverage.unknown && !isempty(elements))
        return event, unsure ? Confidence.possible : Confidence.definite
    end
    return nothing
end

"""
Whole read of filled `array` of constant size after `sure` element writes cover part of it (F34); `nothing` when other
write comes first, or when uses stay unseen.
"""
function placeholder_read(array::ArrayLife)::Union{Nothing, ArrayEvent}
    (array.kind == AllocationKind.filled && !isnothing(array.dimensions)) || return nothing
    elements = Set{Vector{Int}}()
    for event in array.events
        event.kind in UNSEEN && return nothing
        if event.kind == ArrayEventKind.write
            (event.path == ArrayPath.sure && !event.view && event.coverage == Coverage.element) || return nothing
            push!(elements, event.indices)
        elseif event.kind == ArrayEventKind.read && event.coverage == Coverage.whole && !isempty(elements)
            return every_element(elements, array.dimensions) ? nothing : event
        end
    end
    return nothing
end

"""Findings for each array of package method that method reads before write covers element."""
function findings(facts::FactSet)::Vector{Finding}
    lifecycle = facts.lifecycle
    isnothing(lifecycle) && return Finding[]
    found = Finding[]
    for method in lifecycle.methods, array in method.arrays
        unwritten = unwritten_read(array)
        isnothing(unwritten) && continue
        read, confidence = unwritten
        push!(
            found, Finding(
                NAME, :undef_read, confidence, "reads element before any write",
                Label(read.span, "reads unwritten element"), [Label(array.site, "allocates without values here")],
                "`undef` element holds garbage bits, or throws `UndefRefError` for non-bits element",
                manual_fix("write every element first (`fill!`, `copyto!`, or loop over `eachindex`), or allocate with `zeros`, `fill` or `map`"),
            )
        )
    end
    for method in lifecycle.methods, array in method.arrays
        read = placeholder_read(array)
        isnothing(read) && continue
        push!(
            found, Finding(
                NAME, :placeholder, Confidence.possible, "reads whole array after writing part of it",
                Label(read.span, "reads fill value as data"), [Label(array.site, "fills with placeholder here")],
                "elements left at fill value look like data and give wrong result without error",
                manual_fix("write every element before whole read, or keep fill value only where it is data"),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [33, 34], Stage.lifecycle, findings)

end
