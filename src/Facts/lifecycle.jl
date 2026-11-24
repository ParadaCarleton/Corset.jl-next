# Facts of `lifecycle` stage (`lifecycle.md`): arrays that package methods allocate, and events on each.

"""Kind of array allocation (`lifecycle.md`, Allocations)."""
@enumx AllocationKind undef filled broadcast collected slice copied

"""
Kind of array event (`lifecycle.md`, Events): `shape` read, element `read`, `write`, `resize`, `escape`, or `joined` by
`φ` node, after which uses stay unseen.
"""
@enumx ArrayEventKind shape read write resize escape joined

"""Elements that read or write covers: `whole` array, `element` at constant indices, or `unknown`."""
@enumx Coverage whole element unknown

"""
Path of event from its allocation (`lifecycle.md`, Paths): `sure` (runs once on every path that returns), `branch`
(allocation run can skip it), or `loop` (loop that allocation lies outside repeats it).
"""
@enumx ArrayPath sure branch loop

"""
Event on allocated array: statement span, kind, coverage, constant index tuple of `element` coverage, path, Base function
statement calls (`nothing`: other callee or no call), whether event acts through view or wrapper of array (`view`), and
source statement that orders events (`order`).
"""
struct ArrayEvent
    span::Span
    kind::ArrayEventKind.T
    coverage::Coverage.T
    indices::Vector{Int}
    path::ArrayPath.T
    callee::Union{Nothing, Symbol}
    view::Bool
    order::Int
end

"""
Rebind pair (F41): span of array before loop that loop `φ` joins with this broadcast, and whether every array operand
of broadcast is that `φ` value (`same_axes`), so `.=` keeps axes.
"""
struct Rebind
    earlier::Span
    same_axes::Bool
end

"""
Array that package method allocates: allocation span, kind, constant dimensions (`nothing`: unknown), events in source
statement order, and rebind pair (`nothing`: none).
"""
struct ArrayLife
    site::Span
    kind::AllocationKind.T
    dimensions::Union{Nothing, Vector{Int}}
    events::Vector{ArrayEvent}
    rebind::Union{Nothing, Rebind}
end

"""Arrays that one package method allocates, over its units."""
struct MethodArrays
    site::MethodSite
    arrays::Vector{ArrayLife}
end

"""`lifecycle` stage facts: arrays of each package method that allocates one."""
struct LifecycleFacts
    methods::Vector{MethodArrays}
end
