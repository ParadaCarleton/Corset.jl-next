"""
`hidden-input` (F55): method reads default RNG, or package state that other package method writes.

## Description
Reports package method that reads input no argument passes:
- default RNG: `rand()`, `randn()` or `shuffle!(v)` without RNG argument;
- global of package that other package method writes: `const SCALE = Ref(1.0)` that `set_scale!` sets.
Default RNG read passes when caller controls RNG: method takes `AbstractRNG` argument, or package method of its
function takes RNG first (`f(rng, x)` beside convenience method `f(x) = f(default_rng(), x)`).
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
"""
module HiddenInput

using ...Facts

const NAME = Symbol("hidden-input")

"""Input `access` reads: `:default_rng`, package global (`GlobalRef`) in `modules`, or `nothing` for other read."""
function input(access::Access, modules::Vector{Module})::Union{Nothing, Symbol, GlobalRef}
    access.kind == EffectKind.default_rng && return :default_rng
    ref = root_global(access.place)
    return access.kind == EffectKind.memory && !isnothing(ref) && ref.mod in modules ? ref : nothing
end

"""
Package globals that writer method writes, with its write; certain write wins. Write in `__init__` sets state once and
counts for none.
"""
function writers(effects::EffectsFacts, modules::Vector{Module})::Dict{GlobalRef, Tuple{MethodEffects, Access}}
    found = Dict{GlobalRef, Tuple{MethodEffects, Access}}()
    for method in effects.methods, access in method.writes
        ref = root_global(access.place)
        ref isa GlobalRef || continue
        (access.kind == EffectKind.memory && ref.mod in modules && method.site.method.name !== :__init__) || continue
        (!haskey(found, ref) || access.confidence < last(found[ref]).confidence) && (found[ref] = (method, access))
    end
    return found
end

"""Functions (callee types) with package method that takes RNG first: caller of any of their methods can pass RNG."""
rng_functions(package::PackageFacts)::Set{Any} = Set{Any}(tuple_parameters(site.method.sig)[1] for site in package.methods if 1 in rng_positions(site.method))

"""
Whether caller of `method` controls its RNG: method takes RNG argument, whose stand-in can be default RNG, or its
function is in `functions` (`rng_functions`).
"""
chooses_rng(method::Method, functions::Set{Any})::Bool = !isempty(rng_positions(method)) || tuple_parameters(method.sig)[1] in functions

"""Package methods call at `cause` of `method` reaches; none when call reaches other callee too."""
function package_callees(method::MethodEffects, cause::Span, modules::Vector{Module})::Vector{Method}
    found = Method[]
    for call in method.calls
        call.span == cause || continue
        callees = callee_methods(call.callee)
        isnothing(callees) && return Method[]
        append!(found, callees)
    end
    return all(callee -> callee.module in modules, found) ? found : Method[]
end

"""Findings for each package method that reads default RNG or package state, one per input; certain read first."""
function findings(facts::FactSet)::Vector{Finding}
    effects, package = facts.effects, facts.package
    (isnothing(effects) || isnothing(package)) && return Finding[]
    modules, found = package.modules, Finding[]
    written, functions = writers(effects, modules), rng_functions(package)
    # Callee that reads same input reports it, unless its caller controls RNG.
    inputs = Dict(method.site.method => Set{Union{Nothing, Symbol, GlobalRef}}(input(access, modules) for access in method.reads) for method in effects.methods)
    reports(callee::Method, read)::Bool = read in get(inputs, callee, Set{Union{Nothing, Symbol, GlobalRef}}()) && !(read === :default_rng && chooses_rng(callee, functions))
    for method in effects.methods
        own = Set(root_global(access.place) for access in method.writes)
        reads = Dict{Union{Symbol, GlobalRef}, Access}()
        for access in sort(method.reads; by = access -> access.confidence)
            read = input(access, modules)
            (isnothing(read) || haskey(reads, read)) && continue
            hidden = read === :default_rng ? !chooses_rng(method.site.method, functions) : haskey(written, read) && !(read in own)
            hidden || continue
            any(callee -> reports(callee, read), package_callees(method, access.cause, modules)) && continue
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
function input_finding(method::MethodEffects, read::Union{Symbol, GlobalRef}, access::Access, written::Dict{GlobalRef, Tuple{MethodEffects, Access}})::Finding
    if read === :default_rng
        return Finding(
            NAME, :rng, access.confidence, "method draws from default RNG", Label(access.cause, "reads default RNG"),
            [Label(method.site.span, "takes no RNG argument")], "caller cannot seed draws or pass own RNG; concurrent tasks share stream",
            manual_fix("take `rng::AbstractRNG` argument and pass it to each draw"),
        )
    end
    text, (writer, write) = place_text(method.site.method, access.place), written[read]
    return Finding(
        NAME, :global, max(access.confidence, write.confidence), "method reads `$text`, which other method writes", Label(access.cause, "reads `$text`"),
        [Label(writer.site.span, "writes `$text`")], "result depends on state caller cannot see; caller that changes it affects every other caller",
        manual_fix("pass state as argument"),
    )
end

const ENTRY = RuleEntry(NAME, Group.correctness, [55], Stage.effects, findings)

end
