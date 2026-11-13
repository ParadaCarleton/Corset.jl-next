"""
`process-state` (F101): package writes process-wide state.

## Description
Reports writes to `ENV`, `withenv`, and `cd` in any form, in package code only.
Script owns whole process, so rule skips it.
`ENV` writes: index assignment, compound assignment, and `setindex!`, `delete!`, `pop!`, `push!`, `empty!`, `merge!`, `get!` on `ENV`.

## Rationale
Environment and working directory belong to whole process. Other threads see change, and Base docs call `ENV` writes thread-unsafe.
Relative paths in other tasks resolve against new directory while `cd` holds.

## Example
```julia
function build(source)
    cd(source) do
        withenv("CFLAGS" => "-O2") do
            run(`make`)
        end
    end
end
```

## Alternative
```julia
build(source) = run(Cmd(addenv(`make`, "CFLAGS" => "-O2"); dir = source))
```

## Limitations
Reads such as `ENV[key]` and `get(ENV, key, default)` pass. Rule sees `ENV` by name only; alias of `ENV` passes.
"""
module ProcessState

using ...Facts

const NAME = Symbol("process-state")
"""Functions that change dictionary passed as first argument; `get!(f, ENV, key)` passes it second."""
const MUTATORS = ("setindex!", "delete!", "pop!", "push!", "empty!", "merge!", "get!")
const ENV_WHY = "other threads read and write environment at same time; Base docs call it thread-unsafe"
const ENV_FIX = "pass variables to subprocess with `addenv(cmd, key => value)`; pass other settings as arguments"

"""Whether `node` names process environment `ENV`."""
is_env(node::SyntaxNode)::Bool = base_name(node) == "ENV"

"""Whether call `node` changes `ENV` through mutating function."""
function mutates_env(node::SyntaxNode)::Bool
    parts = children_of(node)
    call_head(node) in MUTATORS && length(parts) >= 2 || return false
    return is_env(parts[2]) || (call_head(node) == "get!" && length(parts) >= 3 && is_env(parts[3]))
end

"""Finding at `node` of `kind` with `message`; `cd` and environment writes differ in reason and fix."""
function state_finding(file::SyntaxFile, node::SyntaxNode, kind::Symbol, message::String)::Finding
    return finding(
        NAME, file, node; kind, confidence = Confidence.definite, message,
        label = kind == :working_directory ? "process-wide working directory" : "process-wide environment",
        why = kind == :working_directory ? "relative paths in other tasks resolve against changed directory" : ENV_WHY,
        fix = manual_fix(kind == :working_directory ? "pass directory to subprocess with `Cmd(cmd; dir = path)`; build paths with `joinpath`" : ENV_FIX),
    )
end

"""Findings for writes to `ENV`, `withenv`, and `cd`."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files
        file.role == Role.package || continue
        for node in [forms(file, "="); forms(file, "op=")]
            target = children_of(node)[1]
            kind_name(target) == "ref" && is_env(children_of(target)[1]) || continue
            push!(found, state_finding(file, node, :env_write, "assignment to `$(source(file, target))` changes environment of whole process"))
        end
        for node in forms(file, "call")
            head = call_head(node)
            mutates_env(node) && push!(found, state_finding(file, node, :env_write, "`$head` on `ENV` changes environment of whole process"))
            head == "withenv" && push!(found, state_finding(file, node, :withenv, "`withenv` changes environment of whole process"))
            head == "cd" && push!(found, state_finding(file, node, :working_directory, "`cd` changes working directory of whole process"))
        end
    end
    return sort!(found; by = finding -> finding.primary.span.first_byte)
end

const ENTRY = RuleEntry(NAME, Group.composability, [101], Stage.syntax, run)

end
