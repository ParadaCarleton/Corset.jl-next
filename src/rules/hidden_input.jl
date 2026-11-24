"""
`hidden-input` (F55): method reads default RNG, or package state that other package method writes.

## Description
Reports package method that reads input no argument passes:
- default RNG: `rand()`, `randn()` or `shuffle!(v)` without RNG argument;
- object in package global that other package method writes: `const SCALE = Ref(1.0)` that `set_scale!` sets.
Default RNG read passes when caller controls RNG: package method of same function takes RNG argument beside same
arguments (`f(rng, x)` beside convenience method `f(x) = f(default_rng(), x)`). Method that takes RNG and draws
without it gets finding.
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
Global no package method writes passes: lookup table stays constant. Write in `__init__` sets state once, so it passes too.
Cache write passes: cache read is invisible to caller.
Task-local storage and `ScopedValue` reads pass: logging reads both for every message.
Finding takes weaker certainty of read and write: global that other method may write gives `possible` finding.
Write to other path below same global gives `possible` finding, unless constant values settle both paths.
Read of one field of mutable object gives finding when other method writes other field: facts name objects, not fields.
"""
module HiddenInput

using ...Facts

const NAME = Symbol("hidden-input")

"""Write of package method with method; `writers` keeps them by global."""
const Write = Tuple{MethodEffects, Access}

"""Input `access` reads: `:default_rng`, package global (`GlobalRef`) in `modules`, or `nothing` for other read."""
function input(access::Access, modules::AbstractVector{Module})::Union{Nothing, Symbol, GlobalRef}
    access.kind == EffectKind.default_rng && return :default_rng
    ref = root_global(access.place)
    return access.kind == EffectKind.memory && !isnothing(ref) && ref.mod in modules ? ref : nothing
end

"""Writes of package methods to package globals. Write in `__init__` sets state once and counts for none."""
function writers(effects::EffectsFacts, modules::AbstractVector{Module})::Vector{Write}
    found = Write[]
    for method in effects.methods, access in method.writes
        ref = root_global(access.place)
        ref isa GlobalRef || continue
        (access.kind == EffectKind.memory && ref.mod in modules && method.site.method.name !== :__init__) || continue
        push!(found, (method, access))
    end
    return found
end

"""
Objects `place` passes in value of constant global: root value first, object at place last. `nothing` when value
cannot settle path: other root, element step, or mutable holder, whose fields code can repoint.
"""
function objects(place::Place.Type)::Union{Nothing, Vector{Any}}
    ref, steps = root_global(place), place_steps(place)
    ref isa GlobalRef || return nothing
    isnothing(steps) && return nothing
    isconst(ref.mod, ref.name) || return nothing
    found = Any[getglobal(ref.mod, ref.name)]
    for step in steps
        ismutable(last(found)) && return nothing
        next = step_child(last(found), step)
        isnothing(next) && return nothing
        push!(found, something(next))
    end
    return found
end

"""
Certainty that `write` changes object `read` loads; `nothing` when it cannot. Access covers object at its place, and
objects below it when `below`. Constant values settle both paths (`objects`): `definite` when covered objects meet.
Else on same root: `definite` when path of one starts other and covers rest; `possible` when paths part, since parted
paths can reach one object.
"""
function overlap(read::Access, write::Access)::Union{Nothing, Confidence.T}
    loaded, written = objects(read.place), objects(write.place)
    if !isnothing(loaded) && !isnothing(written)
        meets = last(loaded) === last(written) || (read.below && any(object -> object === last(loaded), written)) || (write.below && any(object -> object === last(written), loaded))
        return meets ? Confidence.definite : nothing
    end
    place_root(read.place) == place_root(write.place) || return nothing
    steps, others = place_steps(read.place), place_steps(write.place)
    (isnothing(steps) || isnothing(others)) && return Confidence.possible
    all(index -> steps[index] == others[index], 1:min(length(steps), length(others))) || return Confidence.possible
    length(steps) == length(others) && return Confidence.definite
    return (length(steps) > length(others) ? write.below : read.below) ? Confidence.definite : nothing
end

"""
Write in `written` that changes object `access` loads (`overlap`), with weaker certainty of write and overlap; most
certain first. `nothing` when none does.
"""
function writer(written::AbstractVector{Write}, access::Access)::Union{Nothing, Tuple{MethodEffects, Access, Confidence.T}}
    found = nothing
    for (method, write) in written
        meets = overlap(access, write)
        isnothing(meets) && continue
        certainty = max(write.confidence, meets)
        (isnothing(found) || certainty < last(found)) && (found = (method, write, certainty))
    end
    return found
end

"""Positions of arguments of `method` (1 is first after callee) whose declared type can hold `AbstractRNG`; `Any` counts for none."""
function rng_positions(method::Method)::Vector{Int}
    parameters, found = tuple_parameters(method.sig), Int[]
    for position in 1:(length(parameters) - 1)
        declared = Base.unwrapva(parameters[position + 1])
        declared isa TypeVar && (declared = declared.ub)
        takes_rng(declared) && push!(found, position)
    end
    return found
end

"""Whether `method` draws from its RNG argument at `position` and never from default RNG."""
function draws_from(method::MethodEffects, position::Integer)::Bool
    accesses = [method.writes; method.reads]
    any(access -> access.kind == EffectKind.default_rng, accesses) && return false
    return any(access -> access.kind == EffectKind.rng_argument && place_root(access.place) == Root.Parameter(position + 1), accesses)
end

"""
Whether caller of `method` can pass RNG instead: package method of same function in `methods` draws from its RNG
argument (`draws_from`), and drops to argument types that accept every call of `method` without it.
"""
function chooses_rng(method::Method, methods::AbstractVector{MethodEffects})::Bool
    parameters = tuple_parameters(method.sig)
    arguments = Base.rewrap_unionall(Tuple{parameters[2:end]...}, method.sig)
    for other in methods
        others = tuple_parameters(other.site.method.sig)
        others[1] == parameters[1] || continue
        for position in rng_positions(other.site.method)
            kept = Base.rewrap_unionall(Tuple{(others[index] for index in 2:length(others) if index != position + 1)...}, other.site.method.sig)
            arguments <: kept && draws_from(other, position) && return true
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
Whether `access` of `method` reads hidden input `read`: default RNG caller cannot replace (`chooses_rng`), or global
memory other method writes (`writer`) and method itself does not. `choices` keeps RNG answer per method.
"""
function hidden(method::MethodEffects, read::Union{Symbol, GlobalRef}, access::Access, written::AbstractVector{Write}, effects::EffectsFacts, choices::IdDict{Method, Bool})::Bool
    read isa GlobalRef || return !get!(() -> chooses_rng(method.site.method, effects.methods), choices, method.site.method)
    return all(write -> isnothing(overlap(access, write)), method.writes) && !isnothing(writer(written, access))
end

"""Findings for each package method that reads default RNG or package state, one per input; certain read first."""
function findings(facts::FactSet)::Vector{Finding}
    effects, package = facts.effects, facts.package
    (isnothing(effects) || isnothing(package)) && return Finding[]
    modules, found = package.modules, Finding[]
    written, choices = writers(effects, modules), IdDict{Method, Bool}()
    # Callee that reads same hidden input reports it.
    hides = IdDict{Method, Set{Union{Symbol, GlobalRef}}}()
    for method in effects.methods, access in method.reads
        read = input(access, modules)
        if !isnothing(read) && hidden(method, read, access, written, effects, choices)
            push!(get!(Set{Union{Symbol, GlobalRef}}, hides, method.site.method), read)
        end
    end
    for method in effects.methods
        reads = Dict{Union{Symbol, GlobalRef}, Access}()
        for access in sort(method.reads; by = access -> access.confidence)
            read = input(access, modules)
            (isnothing(read) || haskey(reads, read) || !hidden(method, read, access, written, effects, choices)) && continue
            any(callee -> haskey(hides, callee) && read in hides[callee], package_callees(method, access.cause, modules)) && continue
            reads[read] = access
        end
        for (read, access) in sort!(collect(reads); by = pair -> (last(pair).cause.first_byte, string(first(pair))))
            push!(found, input_finding(method, read, access, written))
        end
    end
    return found
end

"""
Finding for `read` of `method` at `access`; global read names method that writes it (`written`) and takes weaker
certainty of read and write.
"""
function input_finding(method::MethodEffects, read::Union{Symbol, GlobalRef}, access::Access, written::AbstractVector{Write})::Finding
    if read === :default_rng
        takes = !isempty(rng_positions(method.site.method))
        return Finding(
            NAME, :rng, access.confidence, "method draws from default RNG", Label(access.cause, "reads default RNG"),
            [Label(method.site.span, takes ? "takes RNG argument but draws without it" : "takes no RNG argument")],
            "caller cannot seed draws or pass own RNG; concurrent tasks share stream",
            manual_fix(takes ? "pass RNG argument to each draw" : "take `rng::AbstractRNG` argument and pass it to each draw"),
        )
    end
    writing, write, certainty = something(writer(written, access))
    text = place_text(method.site.method, access.place)
    return Finding(
        NAME, :global, max(access.confidence, certainty), "method reads `$text`, which other method writes", Label(access.cause, "reads `$text`"),
        [Label(writing.site.span, "writes `$(place_text(writing.site.method, write.place))`")],
        "result depends on state caller cannot see; caller that changes it affects every other caller", manual_fix("pass state as argument"),
    )
end

const ENTRY = RuleEntry(NAME, Group.correctness, [55], Stage.effects, findings)

end
