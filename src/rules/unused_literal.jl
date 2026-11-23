"""
`unused-literal` (F97): literal statement has no effect.

## Description
Reports string, number, character, symbol, `nothing`, `true` or `false` statement whose value Julia drops.
Reports string where docstring attaches, when blank line, comment or `;` separates it from definition after it.
Last statement of function, `let`, `begin` or `if` branch gives block value and passes.

## Rationale
Literal statement does nothing. Blank line or comment after docstring detaches it: Julia drops string, and help shows nothing.

## Example
```julia
\"\"\"Area of circle with radius `r`.\"\"\"

area(r) = π * r^2
```

## Alternative
```julia
\"\"\"Area of circle with radius `r`.\"\"\"
area(r) = π * r^2
```

## Limitations
Rule skips code inside macro arguments, since macro may give literal meaning.
Last top-level statement of file passes, since `include` returns its value.
Struct body passes: string there documents field.
Fix turns string into comment; it deletes other literals at `likely`, since comment above may describe them.
"""
module UnusedLiteral

using ...Facts

const NAME = Symbol("unused-literal")
"""Definition kinds docstring documents; assignment counts when it binds name."""
const DEFINITIONS = ("function", "macro", "struct", "abstract", "primitive", "module", "const", "global")
"""Bytes of blank text."""
const BLANK = (UInt8(' '), UInt8('\t'), UInt8('\r'), UInt8('\n'))

"""Whether statement `node` defines what docstring documents, through macros such as `@inline`."""
function defines(node::SyntaxNode)::Bool
    while kind_name(node) == "macrocall"
        node = children_of(node)[end]
    end
    kind_name(node) in DEFINITIONS && return true
    return kind_name(node) == "=" && !isnothing(identifier_name(definition_name(node)))
end

"""Whether `node` sits inside macro call, which may give literal meaning."""
in_macro(node::SyntaxNode)::Bool = any(ancestor -> kind_name(ancestor) == "macrocall", ancestors(node))

"""Fix for detached docstring with `gap` bytes before definition: join when gap is blank, else manual."""
function join_fix(file::SyntaxFile, gap::UnitRange{<:Integer})::Fix
    notes, bytes = comments_in(file, gap), codeunits(file.text)
    any(byte -> bytes[byte] == UInt8(';') && !any(note -> byte in note, notes), gap) &&
        return manual_fix("replace `;` with line break, so definition starts on line below docstring")
    isempty(notes) || return manual_fix("move comment above docstring, then delete lines between docstring and definition")
    space = String(bytes[gap])
    indent = space[(findlast('\n', space) + 1):end]
    return Fix("delete blank lines between docstring and definition", [Edit(Span(file.path, first(gap), last(gap), Precision.exact), "\n" * indent)], Tier.safe)
end

"""Finding for string `node` where docstring attaches, when blank line, comment or `;` splits it from definition `next`."""
function detached(file::SyntaxFile, node::SyntaxNode, next::SyntaxNode)::Union{Nothing, Finding}
    (kind_name(node) == "string" && defines(next) && takes_docstring(file, next)) || return nothing
    return finding(
        NAME, file, node; kind = :detached_docstring, confidence = Confidence.definite,
        message = "docstring is detached from definition", label = "string dropped",
        why = "blank line, comment or `;` ends docstring; Julia drops string, so help shows nothing",
        fix = join_fix(file, (span(file, node).last_byte + 1):(span(file, next).first_byte - 1)),
        causes = [Label(span(file, next), "definition without docstring")],
    )
end

"""
Fix for literal statement `node` alone on its lines: string turns into comment, which keeps its note; other literal goes.
Manual when line holds other code, or when comment above may describe deleted literal.
"""
function drop_fix(file::SyntaxFile, node::SyntaxNode)::Fix
    bytes, bounds = codeunits(file.text), span(file, node)
    start = something(findprev(==(UInt8('\n')), bytes, bounds.first_byte - 1), 0) + 1
    stop = something(findnext(==(UInt8('\n')), bytes, bounds.last_byte + 1), length(bytes))
    alone = all(in(BLANK), view(bytes, start:(bounds.first_byte - 1))) && all(in(BLANK), view(bytes, (bounds.last_byte + 1):stop))
    alone || return manual_fix("delete statement")
    if kind_name(node) == "string"
        indent = String(bytes[start:(bounds.first_byte - 1)])
        text = join(leaf_value(piece) for piece in children_of(node))
        note = join((rstrip(indent * "# " * line) for line in split(text, '\n')), "\n")
        return Fix("turn string into comment", [Edit(Span(file.path, start, bounds.last_byte, Precision.exact), note)], Tier.safe)
    end
    isempty(comment_lines_above(file.text, start)) || return manual_fix("delete statement")
    return Fix("delete statement", [Edit(Span(file.path, start, stop, Precision.exact), "")], Tier.likely)
end

"""Findings for detached docstrings and literal statements whose value Julia drops."""
function findings(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files, block in [forms(file, "block"); forms(file, "toplevel")]
        statements = children_of(block)
        for (index, statement) in enumerate(statements)
            (kind_name(statement) == "string" || literal(statement)) && !in_macro(statement) || continue
            lost = index < length(statements) ? detached(file, statement, statements[index + 1]) : nothing
            if !isnothing(lost)
                push!(found, lost)
            elseif literal(statement) && discarded(statement)
                push!(
                    found, finding(
                        NAME, file, statement; kind = :no_effect, confidence = Confidence.definite,
                        message = "literal statement has no effect", label = "value dropped",
                        why = "Julia evaluates literal and drops its value; statement does nothing",
                        fix = drop_fix(file, statement),
                    )
                )
            end
        end
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.readability, [97], Stage.syntax, findings)

end
