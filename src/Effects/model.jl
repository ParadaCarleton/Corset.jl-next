using Moshi.Derive: @derive

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

"""Effects by place and whether they cover places below."""
const Accesses = Dict{Tuple{Place.Type, Bool}, Effect}

"""Stores of exported graph by holder node and slot."""
const Edges = Dict{Tuple{Node.Type, Step.Type}, Nodes}

"""Stores of exported graph by holder node, for one slot kind: memory backing or unknown slot."""
const Holds = Dict{Node.Type, Nodes}

"""
Effect summary of method instance: writes and reads by place and whether they cover places below; stores between
objects caller can see and fresh objects (`edges` by slot, `backing` for memory, `spread` for unknown slot, `bound`
for global binding); result nodes; count of fresh nodes; and `closed_world`: summary joins methods loaded now, so its
"writes nothing" is at most `possible`. Places need parameters and globals only.
"""
struct Summary
    writes::Accesses
    reads::Accesses
    edges::Edges
    backing::Holds
    spread::Holds
    bound::Dict{GlobalRef, Nodes}
    result::Nodes
    fresh::Int
    closed_world::Bool
end

"""Summary of instance that writes, reads and returns nothing: start of fixpoint inside call cycle."""
empty_summary()::Summary = Summary(Accesses(), Accesses(), Edges(), Holds(), Holds(), Dict{GlobalRef, Nodes}(), Nodes(), 0, false)

"""Whether summaries `first` and `second` hold same effects, stores, result and causes."""
same(first::Summary, second::Summary)::Bool = all(name -> getfield(first, name) == getfield(second, name), fieldnames(Summary))

"""Blind spot cause of access that still changes when call cycle summary widens (`widen`)."""
const UNSETTLED = "unsettled call cycle"

"""Union of `old` and `new` nodes; less doubt wins."""
union_nodes(old::Nodes, new::Nodes)::Nodes = mergewith(min, old, new)

"""Union of `old` and `new` stores by holder."""
union_stores(old::Dict{K, Nodes}, new::Dict{K, Nodes}) where {K} = mergewith(union_nodes, old, new)

"""Union of `old` and `new` accesses: access that differs between them becomes blind (`UNSETTLED`)."""
widen_accesses(old::Accesses, new::Accesses)::Accesses = mergewith((first, second) -> first == second ? first : Effect(Doubt.blind, first.cause, UNSETTLED), old, new)

"""
Summary `new` widened by `old`: union of both; access that differs becomes blind. Join of methods is not monotone, so
call cycle can loop; widened summaries only grow through finite values, so cycle settles.
"""
function widen(old::Summary, new::Summary)::Summary
    writes, reads = widen_accesses(old.writes, new.writes), widen_accesses(old.reads, new.reads)
    edges, backing, spread = union_stores(old.edges, new.edges), union_stores(old.backing, new.backing), union_stores(old.spread, new.spread)
    bound, result = union_stores(old.bound, new.bound), union_nodes(old.result, new.result)
    return Summary(writes, reads, edges, backing, spread, bound, result, max(old.fresh, new.fresh), old.closed_world || new.closed_world)
end

"""
Summary of instance with `count` parameters engine cannot analyze, for blind spot `cause`: blind write and read below
every parameter, result anywhere.
"""
function open_summary(count::Int, cause::String)::Summary
    places = [Place.At(Root.Parameter(position), Step.Type[]) for position in 1:count]
    effects = Accesses((place, true) => Effect(Doubt.blind, 0, cause) for place in places)
    result = Nodes(Node.Placed(place) => Doubt.blind for place in places)
    result[Node.Outside()] = Doubt.blind
    return Summary(effects, copy(effects), Edges(), Holds(), Holds(), Dict{GlobalRef, Nodes}(), result, 0, false)
end
