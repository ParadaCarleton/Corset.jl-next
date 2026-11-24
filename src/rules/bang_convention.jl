"""
`bang-convention` (F53, F86): method writes argument or global state without `!`, or `!` method writes nothing.

## Description
Reports package method whose function name has no `!`, but whose code writes caller-visible state (`missing`):
- memory of argument, of global, or of object no binding names;
- task-local storage.
IO, RNG, synchronization and iteration writes need no `!`.
Write to non-public package global that no other package method reads or writes is cache: it needs no `!`.
Method added to Base IO, synchronization, RNG function or `iterate` passes: name trust lets these functions write.
Reports package method of `!` function that compiler proves writes nothing, and whose result is new value (`spurious`).
Result `nothing`, argument, or value that holds or lies below argument passes: hook, or method with nothing to change.
`!!` functions (mutate when possible) and `sizehint!` (hint) pass.

## Rationale
Caller reads `!` as promise that call can change argument. Missing `!` hides write, and Corset name trust misses it in
callers too. Spurious `!` makes caller drop result, which holds new state.

## Example
```julia
normalize(v::Vector{Float64}) = (v ./= sum(v); v)
```

## Alternative
```julia
normalize!(v::Vector{Float64}) = (v ./= sum(v); v)
```

## Limitations
Fix is manual: rename definition, call sites and exports by hand.
Constructor and callable object pass: their name cannot take `!`. `__init__` passes: it sets state once, at load.
Write that only may happen (`possible`) gives no finding.
`spurious` needs compiler proof of no write for every unit. Method that always throws on stand-ins passes.
"""
module BangConvention

using ...Facts

const NAME = Symbol("bang-convention")

"""Write kinds that need `!` (`effects.md`, `!` convention): memory and task-local storage."""
const STATE_KINDS = (EffectKind.memory, EffectKind.task_local)

"""`!` functions exempt from `spurious`: hint that may write nothing."""
const HINTS = (:sizehint!,)

"""Function `method` adds to: singleton function instance, or `nothing` for constructor or callable object."""
function method_function(method::Method)::Union{Nothing, Function}
    type = tuple_parameters(method.sig)[1]
    (type isa DataType && isdefined(type, :instance)) || return nothing
    callee = type.instance
    return callee isa Function ? callee : nothing
end

"""
Package globals that one package method alone reads or writes, with that method; global several methods touch maps to
`nothing`.
"""
function owners(effects::EffectsFacts, modules::AbstractVector{Module})::Dict{GlobalRef, Union{Nothing, Method}}
    found = Dict{GlobalRef, Union{Nothing, Method}}()
    for method in effects.methods, access in [method.writes; method.reads]
        ref = root_global(access.place)
        (isnothing(ref) || !(ref.mod in modules)) && continue
        found[ref] = get(found, ref, method.site.method) === method.site.method ? method.site.method : nothing
    end
    return found
end

"""Whether `access` of `method` writes cache: non-public package global that only `method` touches (`owners`)."""
function cache_write(access::Access, method::Method, touched::AbstractDict{GlobalRef, Union{Nothing, Method}})::Bool
    ref = root_global(access.place)
    isnothing(ref) && return false
    return !Base.ispublic(ref.mod, ref.name) && get(touched, ref, nothing) === method
end

"""Whether `access` of `method` needs `!`: definite state write to argument, global or unnamed global state, not cache."""
function state_write(access::Access, method::Method, touched::AbstractDict{GlobalRef, Union{Nothing, Method}})::Bool
    (access.kind in STATE_KINDS && access.confidence == Confidence.definite) || return false
    place_root(access.place) == Root.Parameter(1) && return false
    return !cache_write(access, method, touched)
end

"""Fix for method of `callee`: rename for package function, manual change of method for function of other module."""
function rename_fix(callee::Function, modules::AbstractVector{Module}, own::String, other::String)::Fix
    return manual_fix(parentmodule(callee) in modules ? own : other)
end

"""`missing` finding for `method` of `callee` with first definite state write `access`."""
function missing_finding(method::MethodEffects, callee::Function, access::Access, modules::AbstractVector{Module})::Finding
    name, text = string(nameof(callee)), place_text(method.site.method, access.place)
    return Finding(
        NAME, :missing, Confidence.definite, "method of `$name` writes `$text`, but name has no `!`", Label(name_span(method.site), "name has no `!`"),
        [Label(access.cause, "writes `$text`")], "caller reads name without `!` as promise that call changes nothing it can see",
        rename_fix(callee, modules, "rename `$name` to `$(name)!`, with call sites", "copy argument before write, or move write to `!` function"),
    )
end

"""`spurious` finding for `method` of `!` function `callee` that writes nothing and returns new value."""
function spurious_finding(method::MethodEffects, callee::Function, modules::AbstractVector{Module})::Finding
    name = string(nameof(callee))
    return Finding(
        NAME, :spurious, Confidence.definite, "method of `$name` writes nothing, but name ends in `!`", Label(name_span(method.site), "`!` promises write"),
        [Label(method.site.span, "compiler proves no write; result is new value")], "caller trusts `!` and drops result, which holds new state",
        rename_fix(callee, modules, "rename `$name` to `$(chop(name))`, with call sites", "write argument that `$name` promises to change"),
    )
end

"""Findings of package methods that break `!` convention, in method order."""
function findings(facts::FactSet)::Vector{Finding}
    effects, package = facts.effects, facts.package
    (isnothing(effects) || isnothing(package)) && return Finding[]
    modules, found = package.modules, Finding[]
    touched = owners(effects, modules)
    for method in effects.methods
        callee = method_function(method.site.method)
        (isnothing(callee) || startswith(string(nameof(callee)), '#') || nameof(callee) === :__init__) && continue
        name = string(nameof(callee))
        if !method.name_writes
            writes = sort([access for access in method.writes if state_write(access, method.site.method, touched)]; by = access -> access.cause.first_byte)
            isempty(writes) || push!(found, missing_finding(method, callee, first(writes), modules))
        elseif endswith(name, "!") && !endswith(name, "!!") && !(nameof(callee) in HINTS)
            method.effect_free && isempty(method.writes) && method.new_result && push!(found, spurious_finding(method, callee, modules))
        end
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [53, 86], Stage.effects, findings)

end
