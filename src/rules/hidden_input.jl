"""
`hidden-input` (F55): method reads default RNG, or package state that other package method writes.

## Description
Reports package method that reads input no argument passes:
- default RNG: `rand()`, `randn()` or `shuffle!(v)` without RNG argument;
- object in package global that other package method writes: `const SCALE = Ref(1.0)` that `set_scale!` sets.
Default RNG read passes when caller controls RNG: package method of same function takes RNG argument beside same
arguments (`f(rng, x)` beside convenience method `f(x) = f(default_rng(), x)`), or method takes RNG keyword
(`f(x; rng::AbstractRNG = default_rng())`). Method that takes RNG and draws without it gets finding.
Draw inside dependency code labels dependency line. Fix reports it upstream, or passes RNG where dependency offers RNG method.
Read through call to package method that reads same input passes: callee gets finding.
Method that writes global it reads passes: `bang-convention` covers it.

## Rationale
Result depends on state caller cannot see or set. Test cannot fix seed per call, and concurrent callers race on state.

## Example
```julia
jitter(x::Float64) = x + randn()
```

## Alternative
```julia
jitter(rng::AbstractRNG, x::Float64) = x + randn(rng)
jitter(x::Float64) = jitter(Random.default_rng(), x)
```

## Limitations
RNG keyword that keyword body reads passes, even when body draws default RNG too: facts leave out generated methods.
Untyped RNG argument or keyword counts for none: declare `rng::AbstractRNG`.
Sibling that only seeds its RNG argument counts as drawing from it: facts give one kind to every RNG access.
Global no package method writes passes: lookup table stays constant. Write in `__init__` sets state once, so it passes too.
Cache write passes: cache read is invisible to caller.
Task-local storage and `ScopedValue` reads pass: logging reads both for every message.
Finding takes weaker certainty of read and write: global that other method may write gives `possible` finding.
Write to other path below same global gives `possible` finding, unless constant values settle both paths.
Read through mutable holder or non-constant global that now holds written object gives `possible` finding: code can repoint it.
Read of one field of mutable object gives finding when other method writes other field: facts name objects, not fields.
"""
module HiddenInput

using ...Facts

const NAME = Symbol("hidden-input")

"""Write of package method with method."""
const Write = Tuple{MethodEffects, Access}

"""Writes of package methods to package globals, by root global and by each object their path passes now."""
struct Writes
    by_root::Dict{GlobalRef, Vector{Write}}
    by_object::IdDict{Any, Vector{Write}}
end

"""Write that changes object read loads, with certainty; `nothing` for default RNG read."""
const Match = Union{Nothing, Tuple{MethodEffects, Access, Confidence.T}}

"""Hidden input of read, read access, and write that changes it."""
const Hidden = Tuple{Union{Symbol, GlobalRef}, Access, Match}

"""
Input `access` reads: `:default_rng`, package global (`GlobalRef`) in `modules`, or `nothing` for other read. Default
RNG at argument is caller choice, so it hides nothing.
"""
function input(access::Access, modules::AbstractVector{Module})::Union{Nothing, Symbol, GlobalRef}
    access.kind == EffectKind.default_rng && place_root(access.place) == Root.Elsewhere() && return :default_rng
    ref = root_global(access.place)
    return access.kind == EffectKind.memory && !isnothing(ref) && ref.mod in modules ? ref : nothing
end

"""Writes of package methods to package globals. Write in `__init__` sets state once and counts for none."""
function writers(effects::EffectsFacts, modules::AbstractVector{Module})::Writes
    found = Writes(Dict{GlobalRef, Vector{Write}}(), IdDict{Any, Vector{Write}}())
    for method in effects.methods, access in method.writes
        ref = root_global(access.place)
        ref isa GlobalRef || continue
        (access.kind == EffectKind.memory && ref.mod in modules && method.site.method.name !== :__init__) || continue
        push!(get!(Vector{Write}, found.by_root, ref), (method, access))
        passed = current_objects(access.place, true)
        isnothing(passed) && continue
        for object in passed.path
            shares(object) && push!(get!(Vector{Write}, found.by_object, object), (method, access))
        end
    end
    return found
end

"""Whether write can share `object`: `===` compares value of `isbits` type by content, so it names no object."""
shares(@nospecialize(object::Any))::Bool = !isbits(object)

"""Whether `one` and `other` are one object that write can share (`shares`)."""
same_object(@nospecialize(one::Any), @nospecialize(other::Any))::Bool = shares(one) && one === other

"""Whether object paths meet: both end on one object, or path of access that covers objects below ends on other path."""
function meet(read::Access, loaded::AbstractVector, write::Access, written::AbstractVector)::Bool
    same_object(last(loaded), last(written)) && return true
    read.below && any(object -> same_object(object, last(loaded)), written) && return true
    return write.below && any(object -> same_object(object, last(written)), loaded)
end

"""
Certainty that `write` changes object `read` loads when values cannot settle both paths; `nothing` when it cannot. On
same root, paths compare; else `possible` when current objects `meets`.
"""
function path_overlap(read::Access, write::Access, meets::Bool)::Union{Nothing, Confidence.T}
    place_root(read.place) == place_root(write.place) || return meets ? Confidence.possible : nothing
    steps, others = place_steps(read.place), place_steps(write.place)
    (isnothing(steps) || isnothing(others)) && return Confidence.possible
    shared = 1:min(length(steps), length(others))
    all(index -> steps[index] == others[index], shared) || return Confidence.possible
    # Two element steps can name other elements.
    any(index -> steps[index] == Step.Element(), shared) && return Confidence.possible
    length(steps) == length(others) && return Confidence.definite
    covered = length(steps) > length(others) ? write.below : read.below
    return covered ? Confidence.definite : meets ? Confidence.possible : nothing
end

"""
Certainty that `write` changes object `read` loads; `nothing` when it cannot. Access covers object at its place, and
objects below it when `below`. Constant values settle both paths (`current_objects`): `definite` when covered objects meet.
Else on same root: `definite` when path of one starts other and covers rest; `possible` when paths part, since parted
paths can reach one object. Else `possible` when current objects meet through mutable holder.
"""
function overlap(read::Access, write::Access)::Union{Nothing, Confidence.T}
    loaded, written = current_objects(read.place, false), current_objects(write.place, true)
    (isnothing(loaded) || isnothing(written)) && return path_overlap(read, write, false)
    meets = meet(read, loaded.path, write, written.path)
    loaded.settled && written.settled && return meets ? Confidence.definite : nothing
    return path_overlap(read, write, meets)
end

"""Writes in `written` that can change object `access` loads: same root, or path through object read path passes."""
function candidates(written::Writes, access::Access)::Vector{Write}
    found = copy(get(written.by_root, root_global(access.place), Write[]))
    loaded = current_objects(access.place, false)
    isnothing(loaded) && return found
    for object in loaded.path
        shares(object) && append!(found, get(written.by_object, object, Write[]))
    end
    return found
end

"""
Write in `written` that changes object `access` loads (`overlap`), with weaker certainty of write and overlap; most
certain first. `nothing` when none does.
"""
function writer(written::Writes, access::Access)::Match
    found = nothing
    for (method, write) in candidates(written, access)
        meets = overlap(access, write)
        isnothing(meets) && continue
        certainty = max(write.confidence, meets)
        (isnothing(found) || certainty < last(found)) && (found = (method, write, certainty))
    end
    return found
end

"""
Whether method with `reads` draws from its RNG argument at `position` and never surely from default RNG it chose
itself. Default RNG at argument is RNG caller passed there. Method whose callee `possible` draws default RNG (one method
of open dispatch) still takes caller RNG. Draw reads RNG; write alone (task build advances caller RNG) draws nothing.
"""
function draws_from(reads::AbstractVector{Access}, position::Integer)::Bool
    any(access -> access.kind == EffectKind.default_rng && place_root(access.place) == Root.Elsewhere() && access.confidence == Confidence.definite, reads) && return false
    return any(access -> access.kind in (EffectKind.rng_argument, EffectKind.default_rng) && place_root(access.place) == Root.Parameter(position + 1), reads)
end

"""
Whether lowered body of `method` only computes default values and returns call to own function (slot 1) with own
arguments first, as each method that default positional arguments make does: `f(x)` returns `f(x, 10^6, nothing)`.
"""
function fills_defaults(method::Method)::Bool
    (Base.hasgenerator(method) || isnothing(method.source)) && return false
    source = Base.uncompressed_ast(method)
    code = source.code
    returned = last(code)
    returned isa Core.ReturnNode || return false
    isdefined(returned, :val) || return false
    position = returned.val
    position isa Core.SSAValue || return false
    position.id == length(code) - 1 || return false
    call = code[position.id]
    call isa Expr || return false
    (call.head === :call && length(call.args) > method.nargs) || return false
    all(slot -> call.args[slot] == Core.SlotNumber(slot), 1:method.nargs) || return false
    return reads_all_before(source, position.id)
end

"""Whether statement `id` of straight-line lowered `source` reads each earlier statement, directly or through others."""
function reads_all_before(source::Core.CodeInfo, id::Integer)::Bool
    code = source.code
    used = falses(id)
    used[id] = true
    for index in id:-1:1
        used[index] || continue
        statement = code[index]
        statement isa Expr || continue
        for argument in statement.args
            argument isa Core.SSAValue && (used[argument.id] = true)
        end
    end
    return all(used)
end

"""
Argument types of `method` from its signature `parameters` (callee first): first `count` arguments, without argument
`position` (1 is first after callee); `0` drops none.
"""
kept_arguments(method::Method, parameters::Core.SimpleVector, count::Integer, position::Integer)::Type =
    Base.rewrap_unionall(Tuple{(parameters[index] for index in 2:(count + 1) if index != position + 1)...}, method.sig)

"""
Whether caller of `method` can pass RNG instead: `method` takes no RNG argument, and takes RNG keyword (`rng_keyword`),
or package method of same function in `methods` takes RNG at position where caller of `method` can pass one. Sibling
must draw from that RNG argument (`draws_from`) and, without it, accept every call of `method`; `nothing` in place of
RNG argument counts as no argument. Method that same definition makes with more default positional arguments
(`fills_defaults`) needs RNG among them: full method that ignores RNG reports own finding.
"""
function chooses_rng(method::Method, methods::AbstractVector{MethodEffects})::Bool
    isempty(rng_positions(method)) || return false
    rng_keyword(method, false) && return true
    parameters = tuple_parameters(method.sig)
    count = length(parameters) - 1
    for other in methods
        sibling = other.site.method
        others = tuple_parameters(sibling.sig)
        others[1] == parameters[1] || continue
        # Default positional arguments make one method per arity at line of definition.
        defaults = sibling.file == method.file && sibling.line == method.line && length(others) > length(parameters) && fills_defaults(method)
        for position in rng_positions(sibling)
            if defaults
                position > count && kept_arguments(method, parameters, count, 0) <: kept_arguments(sibling, others, count, 0) && return true
            else
                own = length(others) == length(parameters) && parameters[position + 1] === Nothing ? position : 0
                kept_arguments(method, parameters, count, own) <: kept_arguments(sibling, others, length(others) - 1, position) && draws_from(other.reads, position) && return true
            end
        end
    end
    return false
end

"""Package methods call at `cause` of `method` reaches; none when call reaches other callee too."""
function package_callees(method::MethodEffects, cause::Span, modules::AbstractVector{Module})::Vector{Method}
    found = Method[]
    for call in method.calls
        call.span == cause || continue
        callees = callee_methods(call.callee)
        isnothing(callees) && return Method[]
        append!(found, callees)
    end
    return all(callee -> callee.module in modules, found) ? found : Method[]
end

"""
Reads of `method` that take hidden input, certain read first: default RNG caller cannot replace (`chooses_rng`), or
global memory other method writes (`writer`) and method itself does not.
"""
function hidden_reads(method::MethodEffects, written::Writes, effects::EffectsFacts, modules::AbstractVector{Module})::Vector{Hidden}
    found, chooses = Hidden[], nothing
    for access in sort(method.reads; by = access -> access.confidence)
        read = input(access, modules)
        if read isa Symbol
            isnothing(chooses) && (chooses = chooses_rng(method.site.method, effects.methods))
            chooses || push!(found, (read, access, nothing))
        elseif read isa GlobalRef && all(write -> isnothing(overlap(access, write)), method.writes)
            match = writer(written, access)
            isnothing(match) || push!(found, (read, access, match))
        end
    end
    return found
end

"""Findings for each package method that reads default RNG or package state, one per input; certain read first."""
function findings(facts::FactSet)::Vector{Finding}
    effects, package = facts.effects, facts.package
    (isnothing(effects) || isnothing(package)) && return Finding[]
    modules, found = package.modules, Finding[]
    written = writers(effects, modules)
    reads = [hidden_reads(method, written, effects, modules) for method in effects.methods]
    # Callee that reads same hidden input reports it.
    hides = IdDict{Method, Set{Union{Symbol, GlobalRef}}}()
    for (method, entries) in zip(effects.methods, reads), entry in entries
        push!(get!(Set{Union{Symbol, GlobalRef}}, hides, method.site.method), first(entry))
    end
    for (method, entries) in zip(effects.methods, reads)
        kept = Dict{Union{Symbol, GlobalRef}, Hidden}()
        for entry in entries
            read, access = entry[1], entry[2]
            haskey(kept, read) && continue
            any(callee -> haskey(hides, callee) && read in hides[callee], package_callees(method, access.cause, modules)) && continue
            kept[read] = entry
        end
        for entry in sort!(collect(values(kept)); by = entry -> (entry[2].cause.first_byte, string(entry[1])))
            push!(found, input_finding(method, entry))
        end
    end
    return found
end

"""Finding for hidden read `entry` of `method`; global read names method that writes it and takes weaker certainty."""
function input_finding(method::MethodEffects, entry::Hidden)::Finding
    read, access, match = entry
    if read === :default_rng
        takes = !isempty(rng_positions(method.site.method))
        own = Label(method.site.span, takes ? "takes RNG argument but draws without it" : "takes no RNG argument")
        fix = takes ? "pass RNG argument to each draw" : "take `rng::AbstractRNG` argument and pass it to each draw"
        site = access.site
        # Dependency line draws itself: package passes RNG only where dependency offers it, and offer is unproven.
        if !isnothing(site)
            fix = site.offered ? "$fix; report upstream if dependency still draws default RNG" : "dependency draws without RNG; report upstream or allow with reason"
        end
        return Finding(
            NAME, :rng, access.confidence, "method draws from default RNG", Label(access.cause, "reads default RNG"),
            isnothing(site) ? [own] : [own, Label(site.span, "dependency draws without RNG")],
            "caller cannot seed draws or pass own RNG; concurrent tasks share stream", manual_fix(fix),
        )
    end
    writing, write, certainty = something(match)
    text = place_text(method.site.method, access.place)
    return Finding(
        NAME, :global, max(access.confidence, certainty), "method reads `$text`, which other method writes", Label(access.cause, "reads `$text`"),
        [Label(writing.site.span, "writes `$(place_text(writing.site.method, write.place))`")],
        "result depends on state caller cannot see; caller that changes it affects every other caller", manual_fix("pass state as argument"),
    )
end

const ENTRY = RuleEntry(NAME, Group.correctness, [55], Stage.effects, findings)

end
