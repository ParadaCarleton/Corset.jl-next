using Moshi.Data: @data
using Moshi.Derive: @derive

"""Step of access path: named `Field`, tuple `Position`, or `Element` of array memory."""
@data Step begin
    Field(Symbol)
    Position(Int)
    Element()
end
@derive Step[Hash, Eq, Show]

"""
Object access starts from: `Parameter` by argument position (1 is called function), `Global` binding, or `Elsewhere`:
object open call returns, global included.
"""
@data Root begin
    Parameter(Int)
    Global(GlobalRef)
    Elsewhere()
end
@derive Root[Hash, Eq, Show]

"""Object reached from root: `At` path of at most `PATH_DEPTH` steps, or `Deep` past them."""
@data Place begin
    At(Root.Type, Vector{Step.Type})
    Deep(Root.Type)
end
@derive Place[Hash, Eq, Show]

"""Steps of longest exact path; longer paths collapse to `Place.Deep`."""
const PATH_DEPTH = 2

"""
Access to caller-visible object (`effects` stage fact): place, whether it covers every place below it too, kind,
confidence, and cause span in package code. `possible` access from open call is doubt in code; collapsed path gives
blind spot.
"""
struct Access
    place::Place.Type
    below::Bool
    kind::EffectKind.T
    confidence::Confidence.T
    cause::Span
end

"""
Access Corset cannot judge (`effects` stage fact): place, whether it covers places below, kind, and blind spot with
cause (`alias` for collapsed path or merged call result). It counts on coverage line only.
"""
struct BlindAccess
    place::Place.Type
    below::Bool
    kind::EffectKind.T
    spot::BlindSpot
end

"""
Resource hold that throw skips release of (`effects` stage fact, F98): span of acquire, span of statement that may
throw while method holds resource, and confidence: definite count, or `possible` from join of different counts.
"""
struct UnguardedHold
    acquire::Span
    throws::Span
    confidence::Confidence.T
end

"""
Effect summary of package method (`effects` stage fact): writes and reads over its units, blind writes and reads,
places its result aliases, holds throws skip (`unguarded`), `complete`, and `closed_world`. Method with blind access,
or incomplete method (inference skipped some argument types, or stand-ins cut path), has no definite none.
Closed-world method joins methods loaded now: its none is at most `possible`.
"""
struct MethodEffects
    site::MethodSite
    writes::Vector{Access}
    reads::Vector{Access}
    blind_writes::Vector{BlindAccess}
    blind_reads::Vector{BlindAccess}
    aliases::Vector{Place.Type}
    unguarded::Vector{UnguardedHold}
    complete::Bool
    closed_world::Bool
end

"""`effects` stage facts: summary per package method with verdict (`effects.md`, Effects engine)."""
struct EffectsFacts
    methods::Vector{MethodEffects}
end
