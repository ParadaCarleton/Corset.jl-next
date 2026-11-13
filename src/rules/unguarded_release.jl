"""
`unguarded-release` (F98): release skipped when code between acquire and release throws.

## Description
Reports release statement after acquire statement on same target in same block, with code between them.
Pairs: `lock`/`unlock`, `acquire`/`release`, `io = open(…)`/`close(io)`, plain or `Base.` qualified.
Release in `finally` of `try` after acquire passes, since it sits in other block.

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
Rule sees release written as statement of same block. Release nested in `if` or loop passes.
Finding is `definite` though code between acquire and release may never throw.
"""
module UnguardedRelease

using ...Facts

const NAME = Symbol("unguarded-release")

"""Acquire and release patterns of each pair, with finding kind, harm and manual fix text."""
const PAIRS = (
    (
        kind = :lock, acquire = IndexedPattern(@pattern ~or(lock({target}), Base.lock({target}))),
        release = IndexedPattern(@pattern ~or(unlock({target}), Base.unlock({target}))),
        why = "exception between them leaves lock held; next `lock` call waits forever",
        fix = (file::SyntaxFile, acquire::SyntaxNode, ::SyntaxNode) -> "use `$(source(file, acquire)) do … end`",
    ),
    (
        kind = :semaphore, acquire = IndexedPattern(@pattern ~or(acquire({target}), Base.acquire({target}))),
        release = IndexedPattern(@pattern ~or(release({target}), Base.release({target}))),
        why = "exception between them keeps semaphore slot; later `acquire` calls wait for it forever",
        fix = (file::SyntaxFile, acquire::SyntaxNode, release::SyntaxNode) -> "wrap code after `$(source(file, acquire))` in `try … finally $(source(file, release)) end`",
    ),
    (
        kind = :file, acquire = IndexedPattern(@pattern ~or({target:::identifier} = open({_}...), {target:::identifier} = Base.open({_}...))),
        release = IndexedPattern(@pattern ~or(close({target}), Base.close({target}))),
        why = "exception between them leaves file open until garbage collector finalizes it",
        fix = (file::SyntaxFile, acquire::SyntaxNode, release::SyntaxNode) -> "use `$(source(file, children_of(acquire)[2])) do $(source(file, children_of(release)[end])) … end`",
    ),
)

"""Pair index and target source, whitespace runs collapsed, of each acquire or release statement in `file`, by node."""
function sites(file::SyntaxFile, side::Symbol)::IdDict{SyntaxNode, Tuple{Int, String}}
    found = IdDict{SyntaxNode, Tuple{Int, String}}()
    for (index, pair) in enumerate(PAIRS), match in matches(file, pair[side])
        found[match.node] = (index, replace(source(file, binding(match, :target)), r"\s+" => " "))
    end
    return found
end

"""Findings for release statements that run only when code since acquire statement on same target does not throw."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files
        acquires, releases = sites(file, :acquire), sites(file, :release)
        for block in [forms(file, "block"); forms(file, "toplevel")]
            held = Dict{Tuple{Int, String}, Tuple{SyntaxNode, Int}}()
            for (position, statement) in enumerate(children_of(block))
                haskey(acquires, statement) && (held[acquires[statement]] = (statement, position))
                haskey(releases, statement) && haskey(held, releases[statement]) || continue
                acquire, start = pop!(held, releases[statement])
                position == start + 1 && continue
                pair = PAIRS[first(releases[statement])]
                push!(
                    found, finding(
                        NAME, file, statement; kind = pair.kind, confidence = Confidence.definite,
                        message = "`$(source(file, statement))` is skipped when code before it throws",
                        label = "skipped on exception", why = pair.why, fix = manual_fix(pair.fix(file, acquire, statement)),
                        causes = [Label(span(file, acquire), "acquired here")],
                    )
                )
            end
        end
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [98], Stage.syntax, run)

end
