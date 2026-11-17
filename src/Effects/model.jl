"""
Abstract object (`effects.md`, Origins and points-to): `Caller` object at place caller can see, object `Allocation` at
IR statement makes (call statement for all fresh objects of callee), or `Unknown` object open call returns.
"""
@data Origin begin
    Caller(Place.Type)
    Allocation(Int)
    Unknown()
end
@derive Origin[Hash, Eq, Show]

"""Whether `origin` is object instance makes: caller cannot see it before call."""
fresh_origin(origin::Origin.Type)::Bool = @match origin begin
    Origin.Allocation(_) => true
    _ => false
end

"""
Doubt, least first: `none` (definite), `code` (open call: doubt in code, `possible` finding) and `blind` (Corset limit:
blind spot only).
"""
@enumx Doubt none code blind

"""Doubt of chain through steps with `doubts`: most doubtful."""
most(first::Doubt.T, rest::Doubt.T...)::Doubt.T = max(first, rest...)

"""
Origins value may point to, each with doubt of chain to it: `none` when exact, `code` through open call result, `blind`
through collapsed path or merged call result. Two chains to one origin keep less doubt.
"""
const Targets = Dict{Origin.Type, Doubt.T}

"""
Effect on one place: doubt, IR statement where it starts in instance that summary describes, and blind spot cause when
doubt is `blind` (empty otherwise).
"""
struct Effect
    doubt::Doubt.T
    cause::Int
    reason::String
end

"""Effect of two chains on one place: less doubt wins, then earlier cause; order is total, so rounds agree."""
stronger(first::Effect, second::Effect)::Effect = isless((second.doubt, second.cause, second.reason), (first.doubt, first.cause, first.reason)) ? second : first

"""
Node of exported points-to graph: object caller can see at place, `Fresh` object instance makes at IR statement, or
object `Outside` every place.
"""
@data Node begin
    Placed(Place.Type)
    Fresh(Int)
    Outside()
end
@derive Node[Hash, Eq, Show]

"""Nodes value may point to, each with doubt as in `Targets`."""
const Nodes = Dict{Node.Type, Doubt.T}

"""
Effect summary of method instance: writes and reads by place and whether they cover places below; stores between
objects caller can see and fresh objects (`edges` by slot, `backing` for memory, `spread` for unknown slot, `bound`
for global binding); result nodes; and count of fresh nodes. Places need parameters and globals only.
"""
struct Summary
    writes::Dict{Tuple{Place.Type, Bool}, Effect}
    reads::Dict{Tuple{Place.Type, Bool}, Effect}
    edges::Dict{Tuple{Node.Type, Step.Type}, Nodes}
    backing::Dict{Node.Type, Nodes}
    spread::Dict{Node.Type, Nodes}
    bound::Dict{GlobalRef, Nodes}
    result::Nodes
    fresh::Int
end

"""Summary of instance that writes, reads and returns nothing: start of fixpoint inside call cycle."""
empty_summary()::Summary = Summary(Dict(), Dict(), Dict(), Dict(), Dict(), Dict(), Nodes(), 0)

"""Whether summaries `first` and `second` hold same effects, stores, result and causes."""
same(first::Summary, second::Summary)::Bool = all(name -> getfield(first, name) == getfield(second, name), fieldnames(Summary))

"""
Summary of instance with `count` parameters engine cannot analyze, for blind spot `cause`: blind write and read below
every parameter, result anywhere.
"""
function open_summary(count::Int, cause::String)::Summary
    places = [Place.At(Root.Parameter(position), Step.Type[]) for position in 1:count]
    effects = Dict((place, true) => Effect(Doubt.blind, 0, cause) for place in places)
    result = Nodes(Node.Placed(place) => Doubt.blind for place in places)
    result[Node.Outside()] = Doubt.blind
    return Summary(effects, copy(effects), Dict(), Dict(), Dict(), Dict(), result, 0)
end
