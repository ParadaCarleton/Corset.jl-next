"""
`banned` (F82): code matches project ban.

## Description
Reports code that matches `banned` entry in `[preferences.Corset]`: Argus `pattern`, or `name` regex over bound names.
Name regex must match whole name; bound names are parameters, assignment targets, loop variables, definition names and fields.
Each entry gives reason, which finding shows. All entries share one level, as Clippy `disallowed_methods`.

## Rationale
Project rules outside Corset footguns: house conventions, retired APIs, caution markers such as `ccall` that need review.

## Example
```toml
[preferences.Corset]
banned = [
    { pattern = "@show({_}...)", reason = "debug print; use `@debug`" },
    { name = "tmp.*", reason = "name what value holds" },
]
```

## Alternative
Follow reason of entry.

## Limitations
Patterns match syntax as written: alias or import under other name passes.
"""
module Banned

using ...Facts

const NAME = :banned

"""Nodes of `file` that `ban` matches: pattern matches, or bound names regex matches whole."""
function matched(file::SyntaxFile, ban::Ban)::Vector{SyntaxNode}
    ban.target isa Regex || return [match.node for match in matches(file, ban.target)]
    return [site.name for site in file.bindings if occursin(ban.target, identifier_name(site.name))]
end

"""Findings for code that matches project bans."""
function run(facts::FactSet)::Vector{Finding}
    return [
        finding(
            NAME, file, node; kind = ban.target isa Regex ? :name : :pattern, confidence = Confidence.definite,
            message = "`$(source(file, node))` matches project ban `$(ban.text)`", label = "banned by project",
            why = ban.reason, fix = manual_fix("rewrite as ban reason asks"),
        ) for ban in facts.bans for file in facts.files for node in matched(file, ban)
    ]
end

const ENTRY = RuleEntry(NAME, Group.readability, [82], Stage.syntax, run)

end
