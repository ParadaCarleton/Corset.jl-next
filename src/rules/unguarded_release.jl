"""
`unguarded-release` (F98): release skipped when code between acquire and release throws.

## Description
Reports statement that may throw while method holds lock, semaphore slot or open file, outside every `try`.
Hold counts come from release balance of `effects` stage: release in branch or loop counts.
Compiler `nothrow` decides which statements may throw. Finding points at first such statement per resource.

## Rationale
Exception between acquire and release skips release. Held lock deadlocks next caller; held semaphore slot blocks later `acquire`; open file stays open.

## Example
```julia
lock(cache_lock)
cache[key] = compute(key)
unlock(cache_lock)
```

## Alternative
```julia
lock(cache_lock) do
    cache[key] = compute(key)
end
```

## Limitations
Rule sees package methods inference reaches. Script code gets no finding.
Package function that takes held resource can release it, so count after its call is unknown and finding `possible`.
Helper that acquires for its caller (`hold!(q) = lock(q.lock)`) gives caller no finding.
"""
module UnguardedRelease

using ...Facts

const NAME = Symbol("unguarded-release")

"""Finding text of each resource kind: resource, its state while held, cause label, harm and manual fix."""
const TEXTS = Dict(
    EffectKind.synchronization => (
        resource = "lock", state = "held", acquired = "acquired here",
        why = "throw skips release; lock or semaphore slot stays held, so next caller waits forever",
        fix = "hold with `lock(l) do … end` or `@lock l expr`, or release in `finally`",
    ),
    EffectKind.io => (
        resource = "file", state = "open", acquired = "opened here",
        why = "throw skips `close`; file stays open until garbage collector finalizes it",
        fix = "use `open(path) do io … end`, or close in `finally`",
    ),
)

"""Findings for each statement that may throw while package method holds resource outside every `try`."""
function findings(facts::FactSet)::Vector{Finding}
    effects = facts.effects
    isnothing(effects) && return Finding[]
    found = Finding[]
    for method in effects.methods, hold in method.unguarded
        text = TEXTS[hold.kind]
        push!(
            found, Finding(
                NAME, Symbol(text.resource), hold.confidence, "$(text.resource) stays $(text.state) when this statement throws",
                Label(hold.throws, "may throw while $(text.resource) is $(text.state)"), [Label(hold.acquire, text.acquired)], text.why,
                manual_fix(text.fix),
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [98], Stage.effects, findings)

end
