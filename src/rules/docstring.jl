"""
`docstring` (F74, F80): comment where docstring belongs; module without docstring.

## Description
Reports comment block directly above function or struct where docstring attaches, and module without docstring.
Docstring attaches at top level, in module body and in `begin` block; function, `let` and loop bodies drop it.

## Rationale
Help mode (`?name`) and documentation tools read docstrings only. Comment above definition stays invisible to them.

## Example
```julia
# Area of circle with radius `r`.
area(r) = π * r^2
```

## Alternative
```julia
\"\"\"Area of circle with radius `r`.\"\"\"
area(r) = π * r^2
```

## Limitations
Fix turns comment into docstring as written; review wording after fix.
"""
module Docstring

using ...Facts

const NAME = :docstring

"""Whether `node` carries docstring: parent is `doc` node."""
documented(node::SyntaxNode)::Bool = (parent = parent_of(node); !isnothing(parent) && kind_name(parent) == "doc")

"""Whether line above byte `first`, where comment block starts, holds code; `false` at file start."""
function code_above(text::String, first::Integer)::Bool
    first <= 2 && return false
    start = something(findprev(==(UInt8('\n')), codeunits(text), first - 2), 0) + 1
    line = strip(SubString(text, start, prevind(text, first - 1)))
    return !isempty(line) && !startswith(line, "#")
end

"""Comment text `line` as string source with same value: backslash, dollar sign and quote that could close string get escaped."""
escaped(line::AbstractString)::String = replace(line, '\\' => "\\\\", '$' => "\\\$", r"\"(?=\"|$)" => "\\\"")

"""Text of byte range `line` of `text`; range ends on last byte of character, which `thisind` turns into its index."""
line_text(text::String, line::UnitRange{<:Integer})::String = text[first(line):thisind(text, last(line))]

"""Docstring text built from comment lines `lines` of `text`, with indentation `indent`."""
function as_docstring(text::String, lines::AbstractVector{<:UnitRange{<:Integer}}, indent::String)::String
    body = [escaped(lstrip(chopprefix(lstrip(line_text(text, line)), "#"))) for line in lines]
    return length(body) == 1 ? "$indent\"\"\"$(body[1])\"\"\"" :
        "$indent\"\"\"\n" * join((indent * line for line in body), "\n") * "\n$indent\"\"\""
end

"""Findings for definitions under comment block where docstring attaches, and modules without docstring."""
function findings(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files
        for definition in [forms(file, "function"); forms(file, "struct")]
            (documented(definition) || !takes_docstring(file, definition)) && continue
            lines = comment_lines_above(file.text, span(file, definition).first_byte)
            isempty(lines) && continue
            indent = String(match(r"^[ \t]*", line_text(file.text, lines[1])).match)
            block = Span(file.path, first(lines[1]), last(lines[end]), Precision.exact)
            # String statement right above new docstring would document it; blank line keeps them apart.
            docstring = (code_above(file.text, first(lines[1])) ? "\n" : "") * as_docstring(file.text, lines, indent)
            push!(
                found, finding(
                    NAME, file, definition; kind = :comment_above, confidence = Confidence.definite,
                    message = "comment above definition is not docstring", label = "definition without docstring",
                    why = "help mode, Documenter and language server show docstrings; comments stay invisible",
                    fix = Fix("turn comment into docstring", [Edit(block, docstring)], Tier.safe),
                    causes = [Label(block, "comment")],
                )
            )
        end
        for definition in forms(file, "module")
            documented(definition) && continue
            push!(
                found, finding(
                    NAME, file, definition; kind = :module_without_docstring, confidence = Confidence.definite,
                    message = "module `$(source(file, children_of(definition)[1]))` has no docstring",
                    label = "undocumented module", why = "users reach package through module help first",
                    fix = manual_fix("add docstring above `module`: what package does, main entry points"),
                )
            )
        end
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.readability, [74, 80], Stage.syntax, findings)

end
