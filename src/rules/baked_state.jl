"""
`baked-state` (F100): precompile bakes run-time value into global.

## Description
Reports global assigned at module top level from expression that reads run-time state, in package code only.
State: thread count, `ENV`, home, working and temporary directory, clock, random numbers, host name, process ID, pointers.
Top level spans module body, `begin`, `if`, `global` in `let`, `@static` and `@eval`.
Function bodies, closures and `__init__` run later and pass. Arguments of other macros pass: macro decides whether they run.
Scripts never precompile, so rule skips them.

## Rationale
Precompile runs module top level once and stores globals in cache. Each later session loads value of build session: wrong thread count, old path, null pointer.

## Example
```julia
const NTHREADS = Threads.nthreads()
```

## Alternative
```julia
const NTHREADS = Ref(0)
__init__() = NTHREADS[] = Threads.nthreads()
```

## Limitations
Rule sees state read inside assigned expression. Value passed through local variable, or read in `if` condition, passes.
Assignment in top-level `for`, `while` or `try` passes. Closure called at once, as in `foreach(f) do … end`, passes.
"""
module BakedState

using ...Facts

const NAME = Symbol("baked-state")

"""Patterns of run-time state reads by finding kind, with harm of baking each."""
const READS = (
    (
        kind = :thread_count, why = "cache keeps thread count of build session; sessions with other thread count still see it",
        pattern = IndexedPattern(@pattern ~or(nthreads(), Threads.nthreads(), Base.Threads.nthreads(), Sys.CPU_THREADS, Base.Sys.CPU_THREADS)),
    ),
    (
        kind = :environment, why = "cache keeps environment of build session; later changes to variable have no effect",
        pattern = IndexedPattern(@pattern ~or(ENV[{_}], get(ENV, {_}...))),
    ),
    (
        kind = :path, why = "cache keeps directory of build session; other users, machines and directories get wrong path",
        pattern = IndexedPattern(@pattern ~or(homedir(), pwd(), tempdir())),
    ),
    (
        kind = :clock, why = "cache keeps build time; every session sees same old time",
        pattern = IndexedPattern(@pattern ~or(time(), time_ns(), now({_}...), Dates.now({_}...))),
    ),
    (kind = :random, why = "cache keeps one draw; every session gets same value", pattern = IndexedPattern(@pattern ~or(rand({_}...), randn({_}...)))),
    (kind = :host, why = "cache keeps host name of build machine", pattern = IndexedPattern(@pattern gethostname())),
    (kind = :process, why = "cache keeps ID of build process, which has ended", pattern = IndexedPattern(@pattern getpid())),
    (
        kind = :pointer, why = "cache resets pointer to null; later sessions crash or fail through it",
        pattern = IndexedPattern(@pattern ~or(dlopen({_}...), Libdl.dlopen({_}...), cglobal({_}...), pointer({_}...))),
    ),
)

"""Kinds whose body runs later, when called."""
const DEFERRED = ("function", "->", "do", "macro")
"""Kinds that keep code at module top level: code runs now, and assignment sets global."""
const TOP_LEVEL = ("toplevel", "module", "block", "if", "elseif", "doc", "const", "global")
"""Macros whose argument runs as module top-level code. Other macros get syntax, such as Argus `@pattern`, and may never run it."""
const TRANSPARENT = ("@static", "@eval")

"""Whether `node` calls macro outside `TRANSPARENT`."""
opaque_macro(node::SyntaxNode)::Bool = kind_name(node) == "macrocall" && base_macro(node) ∉ TRANSPARENT

"""Whether `node` keeps code at module top level; `let` does so only for assignment marked `global`."""
top_level(node::SyntaxNode, global_assignment::Bool)::Bool =
    kind_name(node) in TOP_LEVEL || (kind_name(node) == "let" && global_assignment) || (kind_name(node) == "macrocall" && !opaque_macro(node))

"""Target of outermost assignment whose value `read` computes, when it sets global at module top level; else `nothing`."""
function baked_target(read::SyntaxNode)::Union{Nothing, SyntaxNode}
    assignment, child = nothing, read
    for ancestor in ancestors(read)
        (kind_name(ancestor) in DEFERRED || opaque_macro(ancestor)) && return nothing
        kind_name(ancestor) == "=" && children_of(ancestor)[2] === child && (assignment = ancestor)
        child = ancestor
    end
    isnothing(assignment) && return nothing
    global_assignment = kind_name(parent_of(assignment)) == "global"
    return all(node -> top_level(node, global_assignment), ancestors(assignment)) ? children_of(assignment)[1] : nothing
end

"""Findings for run-time state read into global at module top level of package file, where precompile stores it."""
function findings(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files
        file.role == Role.package || continue
        for read in READS, match in matches(file, read.pattern)
            target = baked_target(match.node)
            isnothing(target) && continue
            push!(
                found, finding(
                    NAME, file, match.node; kind = read.kind, confidence = Confidence.definite,
                    message = "`$(source(file, target))` bakes in `$(source(file, match.node))` at precompile time",
                    label = "read when package precompiles", why = read.why,
                    fix = manual_fix("compute in `__init__` and store in `Ref`, or read at call time"),
                    causes = [Label(span(file, target), "value stored in precompile cache")],
                )
            )
        end
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [100], Stage.syntax, findings)

end
