"""
`false-effects` (F58): own analysis contradicts `@assume_effects` claim of package method.

## Description
Reports package method whose `@assume_effects` claim `effects` stage disproves:
- `:effect_free`: method writes memory caller sees.
- `:inaccessiblememonly`: method writes memory caller sees, or reads global or task state.
- `:notaskstate`: method reads or writes task-local state, default RNG or `ScopedValue`.
- `:consistent`: method reads global or task state, so equal arguments can give other result.
Writes to lazy-init and audited Base internal state pass: caller cannot see them.

## Rationale
Compiler trusts claim without check. False claim lets compiler delete, move or constant-fold calls, so code
misbehaves only after optimization, and only in some builds.

## Example
```julia
const CALLS = Ref(0)
Base.@assume_effects :effect_free function scaled(x::Float64)
    CALLS[] += 1
    return 2x
end
```

## Alternative
```julia
const CALLS = Ref(0)
function scaled(x::Float64)
    CALLS[] += 1
    return 2x
end
```

## Limitations
Rule checks claims on method only; claim on block inside method passes.
Rule cannot check `:nothrow`, `:terminates_globally`, `:terminates_locally`, `:noub` and `:nortcall`.
Read of argument memory passes `:consistent` and `:inaccessiblememonly` checks: access fact cannot tell mutable argument from immutable one.
Finding takes certainty of access that contradicts claim.
"""
module FalseEffects

using ...Facts

const NAME = Symbol("false-effects")

"""Kinds of task state, each with its name in finding text: task-local storage, default RNG and `ScopedValue`."""
const TASK_STATE = Dict(EffectKind.task_local => "task-local storage", EffectKind.default_rng => "default RNG", EffectKind.scoped_read => "`ScopedValue`")

"""Kinds of internal state caller cannot see: lazy init and audited Base state."""
const HIDDEN = (EffectKind.lazy_init, EffectKind.audited)

"""
Accesses of `method` that contradict `claim` (`Base.EffectsOverride` field name), each with verb that says what access
does. Claim rule cannot check gives none.
"""
function contradictions(method::MethodEffects, claim::Symbol)::Vector{Tuple{String, Access}}
    seen = [("writes", access) for access in method.writes if !(access.kind in HIDDEN)]
    task = [(verb, access) for (verb, accesses) in (("writes", method.writes), ("reads", method.reads)) for access in accesses if haskey(TASK_STATE, access.kind)]
    state = [("reads", access) for access in method.reads if haskey(TASK_STATE, access.kind) || (!isnothing(root_global(access.place)) && !(access.kind in HIDDEN))]
    claim === :effect_free && return seen
    claim === :inaccessiblememonly && return [seen; state]
    claim === :notaskstate && return task
    claim === :consistent && return state
    return Tuple{String, Access}[]
end

"""Findings for each `@assume_effects` claim of package method that own analysis contradicts; definite access first."""
function findings(facts::FactSet)::Vector{Finding}
    effects = facts.effects
    isnothing(effects) && return Finding[]
    found = Finding[]
    for method in effects.methods, claim in method.claims
        against = sort!(contradictions(method, claim); by = ((_, access),) -> access.confidence)
        isempty(against) && continue
        verb, access = first(against)
        what = haskey(TASK_STATE, access.kind) ? "$verb $(TASK_STATE[access.kind])" : "$verb `$(place_text(method.site.method, access.place))`"
        push!(
            found, Finding(
                NAME, claim, access.confidence, "method claims `:$claim`, but $what", Label(method.site.span, "claims `:$claim`"),
                [Label(access.cause, what)], "compiler trusts claim without check; false claim lets it delete, move or fold calls",
                manual_fix("drop `:$claim` from `@assume_effects`, or remove access"),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [58], Stage.effects, findings)

end
