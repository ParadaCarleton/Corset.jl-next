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
Doubt level, least first: `none` (definite), `code` (open call: doubt in code, `possible` finding) and `blind` (Corset
limit: blind spot only).
"""
@enumx Level none code blind

"""Sources of `code` doubt as bits, and bits of `Doubt`."""
const Sources = UInt32

"""Bit of `Doubt` for `blind` level; sources use bits below it."""
const BLIND = Sources(1) << (8 * sizeof(Sources) - 1)

"""
Doubt of chain or effect (`effects.md`, Provenance): level (`level_of`), and for `code` level its sources as bits
(`sources_of`). `INHERENT`: doubt in code itself. `OPAQUE`: type Corset chose. Bit `p` (`parameter_source`): open type
of parameter `p`; caller decides. Packed in 4 bytes, since targets and effects copy it in every round: `none` is 0,
`blind` is `BLIND` alone, `code` doubt is its sources.
"""
struct Doubt
    bits::Sources
    function Doubt(level::Level.T, sources::Sources)::Doubt
        (level == Level.code) == (sources != 0) || throw(ArgumentError("doubt has sources exactly at `code` level: $level, $sources"))
        sources & BLIND == 0 || throw(ArgumentError("doubt sources use bits below `BLIND`: $sources"))
        return new(level == Level.blind ? BLIND : sources)
    end
end

"""Level of `doubt`."""
level_of(doubt::Doubt)::Level.T = doubt.bits == 0 ? Level.none : doubt.bits == BLIND ? Level.blind : Level.code

"""Sources of `doubt`: none below `code` level and above it."""
sources_of(doubt::Doubt)::Sources = doubt.bits & ~BLIND

"""Source bit of doubt in code itself: no parameter type resolves it."""
const INHERENT = Sources(1)

"""Last parameter with own source bit; later parameters count as `INHERENT`."""
const LAST_PARAMETER = 8 * sizeof(Sources) - 3

"""Source bit of open type Corset chose: `FunctionStandIn` argument."""
const OPAQUE = Sources(1) << (LAST_PARAMETER + 1)

"""Source bits of parameters 1 to `LAST_PARAMETER`."""
const PARAMETERS = (Sources(1) << (LAST_PARAMETER + 1)) - Sources(2)

"""Source bit of parameter `position` (callee is 1); past `LAST_PARAMETER`, `INHERENT`."""
parameter_source(position::Int)::Sources = 1 <= position <= LAST_PARAMETER ? Sources(1) << position : INHERENT

"""No doubt: definite."""
const NO_DOUBT = Doubt(Level.none, Sources(0))

"""Doubt in code itself."""
const CODE_DOUBT = Doubt(Level.code, INHERENT)

"""Blind doubt: Corset limit."""
const BLIND_DOUBT = Doubt(Level.blind, Sources(0))

"""
Doubt of chain through steps with `first` and `second`: most doubtful level. Two `code` doubts join sources: doubt is
in code when either source is.
"""
function most(first::Doubt, second::Doubt)::Doubt
    level_of(first) == level_of(second) && return Doubt(level_of(first), sources_of(first) | sources_of(second))
    return level_of(first) > level_of(second) ? first : second
end

"""
Doubt of two chains to one origin: least doubtful level. Two `code` doubts join sources: access through either chain is
`possible` when its source is code.
"""
function least(first::Doubt, second::Doubt)::Doubt
    level_of(first) == level_of(second) && return Doubt(level_of(first), sources_of(first) | sources_of(second))
    return level_of(first) < level_of(second) ? first : second
end

"""
Origins value may point to, each with doubt of chain to it: none when exact, `code` through open call result, `blind`
through collapsed path or merged call result. Two chains to one origin keep less doubt (`least`).
"""
const Targets = Dict{Origin.Type, Doubt}

"""
Effect on one place: doubt, IR statement where it starts in instance that summary describes, and blind spot cause when
doubt is `blind` (empty otherwise).
"""
struct Effect
    doubt::Doubt
    cause::Int
    reason::String
end

"""
Effect of two chains on one place: less doubt (`least`), cause and reason of chain with lower level, then earlier
cause; order is total, so rounds agree.
"""
function stronger(first::Effect, second::Effect)::Effect
    chosen = isless((level_of(second.doubt), second.cause, second.reason), (level_of(first.doubt), first.cause, first.reason)) ? second : first
    return Effect(least(first.doubt, second.doubt), chosen.cause, chosen.reason)
end

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
const Nodes = Dict{Node.Type, Doubt}

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

"""Union of `old` and `new` nodes; less doubt wins (`least`)."""
union_nodes(old::Nodes, new::Nodes)::Nodes = mergewith(least, old, new)

"""Union of `old` and `new` stores by holder."""
(union_stores(old::Dict{K, Nodes}, new::Dict{K, Nodes})::Dict{K, Nodes}) where {K} = mergewith(union_nodes, old, new)

"""Union of `old` and `new` accesses: access that differs between them becomes blind (`UNSETTLED`)."""
widen_accesses(old::Accesses, new::Accesses)::Accesses = mergewith((first, second) -> first == second ? first : Effect(BLIND_DOUBT, first.cause, UNSETTLED), old, new)

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
    effects = Accesses((place, true) => Effect(BLIND_DOUBT, 0, cause) for place in places)
    result = Nodes(Node.Placed(place) => BLIND_DOUBT for place in places)
    result[Node.Outside()] = BLIND_DOUBT
    return Summary(effects, copy(effects), Edges(), Holds(), Holds(), Dict{GlobalRef, Nodes}(), result, 0, false)
end
