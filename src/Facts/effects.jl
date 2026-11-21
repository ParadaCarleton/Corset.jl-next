using Moshi.Data: @data
using Moshi.Derive: @derive
using Moshi.Match: @match

"""Step of access path: named `Field`, tuple `Position`, or `Element` of array memory."""
@data Step begin
    Field(Symbol)
    Position(Int)
    Element()
end
@derive Step[Show]

"""
Object access starts from: `Parameter` by argument position (1 is called function), `Global` binding, or `Elsewhere`:
object open call returns, global included.
"""
@data Root begin
    Parameter(Int)
    Global(GlobalRef)
    Elsewhere()
end
@derive Root[Show]

"""Object reached from root: exact `At` path, or `Deep`: some object below root past exact path."""
@data Place begin
    At(Root.Type, Vector{Step.Type})
    Deep(Root.Type)
end
@derive Place[Show]

# Hash tables test key equality on every hit. Derived `Eq` finds variant by subtype test; matching is many times faster.

"""Whether steps `first` and `second` are equal."""
Base.:(==)(first::Step.Type, second::Step.Type)::Bool = @match (first, second) begin
    (Step.Field(one), Step.Field(other)) => one === other
    (Step.Position(one), Step.Position(other)) => one == other
    (Step.Element(), Step.Element()) => true
    _ => false
end

"""Whether roots `first` and `second` are equal."""
Base.:(==)(first::Root.Type, second::Root.Type)::Bool = @match (first, second) begin
    (Root.Parameter(one), Root.Parameter(other)) => one == other
    (Root.Global(one), Root.Global(other)) => one == other
    (Root.Elsewhere(), Root.Elsewhere()) => true
    _ => false
end

"""Whether places `first` and `second` are equal: same root and steps."""
Base.:(==)(first::Place.Type, second::Place.Type)::Bool = @match (first, second) begin
    (Place.At(one, steps), Place.At(other, others)) => one == other && steps == others
    (Place.Deep(one), Place.Deep(other)) => one == other
    _ => false
end

"""Equality of steps, roots and places: their fields hold no floating-point or `missing` value."""
(Base.isequal(first::T, second::T)::Bool) where {T <: Union{Step.Type, Root.Type, Place.Type}} = first == second

# Derived `Hash` hashes steps through generic array hash and module by object id; tags and loops are faster.

"""Hash of `step`: variant tag, then its field."""
Base.hash(step::Step.Type, seed::UInt)::UInt = @match step begin
    Step.Field(name) => hash(name, hash(0x01, seed))
    Step.Position(index) => hash(index, hash(0x02, seed))
    Step.Element() => hash(0x03, seed)
end

"""Hash of `root`: variant tag, then its field; global by module name and binding name."""
Base.hash(root::Root.Type, seed::UInt)::UInt = @match root begin
    Root.Parameter(position) => hash(position, hash(0x11, seed))
    Root.Global(binding) => hash(binding.name, hash(nameof(binding.mod), hash(0x12, seed)))
    Root.Elsewhere() => hash(0x13, seed)
end

"""Hash of `place`: variant tag, root, then each step."""
Base.hash(place::Place.Type, seed::UInt)::UInt = @match place begin
    Place.At(root, steps) => steps_hash(steps, hash(root, hash(0x21, seed)))
    Place.Deep(root) => hash(root, hash(0x22, seed))
end

"""Hash of `steps` after `seed`, one step at a time."""
function steps_hash(steps::Vector{Step.Type}, seed::UInt)::UInt
    for step in steps
        seed = hash(step, seed)
    end
    return seed
end

"""Steps of longest exact path; declared field types collapse most paths earlier (`effects.md`, Origins and points-to)."""
const PATH_DEPTH = 8

"""Source text of `step` after its object: `.field`, `[position]` or `[…]` for array element."""
step_text(step::Step.Type)::String = @match step begin
    Step.Field(name) => "." * string(name)
    Step.Position(position) => "[$position]"
    Step.Element() => "[…]"
end

"""
Source text of `root` in `method`: argument name (closure itself for argument 1 of anonymous function), qualified
global name, or open call result.
"""
root_text(method::Method, root::Root.Type)::String = @match root begin
    Root.Parameter(position) => (name = Base.method_argnames(method)[position]; name === Symbol("#self#") ? "closure" : string(name))
    Root.Global(binding) => string(binding.mod, ".", binding.name)
    Root.Elsewhere() => "result of open call"
end

"""Source text of `place` in `method`, as code writes path to it: `items.data[…]`; `Deep` place adds `or below`."""
place_text(method::Method, place::Place.Type)::String = @match place begin
    Place.At(root, steps) => root_text(method, root) * join(step_text.(steps))
    Place.Deep(root) => root_text(method, root) * " or below"
end

"""Global binding `place` starts at; `nothing` for place at argument or elsewhere."""
root_global(place::Place.Type)::Union{Nothing, GlobalRef} = @match place begin
    Place.At(Root.Global(ref), _) => ref
    Place.Deep(Root.Global(ref)) => ref
    _ => nothing
end

"""
Access to caller-visible object (`effects` stage fact): place, whether it covers every place below it too, kind,
confidence, and cause span in package code. `possible` access from open call is doubt in code. `Deep` place keeps
certainty: object lies below its root.
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
throw while method holds resource, resource kind (`synchronization`: lock or semaphore slot; `io`: file), and
confidence: definite count, or `possible` from join of different counts.
"""
struct UnguardedHold
    acquire::Span
    throws::Span
    kind::EffectKind.T
    confidence::Confidence.T
end

"""
Callee of call statement: `Methods` that dispatch reaches (none when no method matches: call throws), `Builtin` or
intrinsic function, `Foreign` C function, or `Open` dispatch (Base contract, open or unresolved call).
"""
@data Callee begin
    Methods(Vector{Method})
    Builtin(Core.Builtin)
    Foreign()
    Open()
end
@derive Callee[Hash, Eq, Show]

"""
Callee `Methods` of `methods`, each once, in source order: module, file, line, signature. Dispatch and unit merge give
methods in varying order, so facts and their equality depend on none.
"""
methods_callee(methods::Vector{Method})::Callee.Type = Callee.Methods(sort!(unique(methods); by = method -> (string(method.module), string(method.file), method.line, string(method.sig))))

"""Name of function `callee` calls: method name shared by every method, or builtin name; else `nothing`."""
callee_name(callee::Callee.Type)::Union{Nothing, String} = @match callee begin
    Callee.Methods(methods) => (names = unique(method.name for method in methods); length(names) == 1 ? string(only(names)) : nothing)
    Callee.Builtin(builtin) => string(nameof(builtin))
    _ => nothing
end

"""Methods of `callee` that dispatch reaches (none: call throws); `nothing` for builtin, foreign or open callee."""
callee_methods(callee::Callee.Type)::Union{Nothing, Vector{Method}} = @match callee begin
    Callee.Methods(methods) => methods
    _ => nothing
end

"""
Call statement of package method (`effects` stage fact, F54, F56, F86): span, callee, and kinds of writes call makes
at any certainty, holds it leaves included; `definite` keeps kinds of writes without doubt. Compiler effects give
`throws` (may throw) and `terminates`. `used`: code reads result. `closed_world`: call verdict joins methods loaded now
(Base contract, dispatch to several methods, or callee that joins). `stand_in`: operand type holds stand-in, so
compiler flags and writes hold for stand-in type only. Either makes its none at most `possible`. Units of method
merge: any unit that may throw, writes, uses result, joins or has stand-in operand decides.
"""
struct CallFact
    span::Span
    callee::Callee.Type
    kinds::Vector{EffectKind.T}
    definite::Vector{EffectKind.T}
    throws::Bool
    terminates::Bool
    used::Bool
    closed_world::Bool
    stand_in::Bool
end

"""
Effect summary of package method (`effects` stage fact): writes and reads over its units, blind writes and reads,
places its result aliases, holds throws skip (`unguarded`), call statements (`calls`, by span), `complete`,
`closed_world`, and effects `@assume_effects` on method claims (`claims`, `Base.EffectsOverride` field names). Method
with blind access, or incomplete method (inference skipped some argument types, or stand-ins cut path), has no definite
none. Closed-world method joins methods loaded now: its none is at most `possible`.
"""
struct MethodEffects
    site::MethodSite
    writes::Vector{Access}
    reads::Vector{Access}
    blind_writes::Vector{BlindAccess}
    blind_reads::Vector{BlindAccess}
    aliases::Vector{Place.Type}
    unguarded::Vector{UnguardedHold}
    calls::Vector{CallFact}
    complete::Bool
    closed_world::Bool
    claims::Vector{Symbol}
end

"""`effects` stage facts: summary per package method with verdict (`effects.md`, Effects engine)."""
struct EffectsFacts
    methods::Vector{MethodEffects}
end
