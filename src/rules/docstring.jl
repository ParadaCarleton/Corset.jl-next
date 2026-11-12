"""`docstring` (F74, F80): comment where docstring belongs; module without docstring."""
module Docstring

using ...Facts

const NAME = :docstring

"""Whether `node` carries docstring: parent is `doc` node."""
documented(node)::Bool = (parent = parent_of(node); !isnothing(parent) && kind_name(parent) == "doc")

"""Byte ranges of comment lines directly above byte `first` in `text`, top first; blank line ends block."""
function comment_lines_above(text::String, first::Int)::Vector{UnitRange{Int}}
    lines = UnitRange{Int}[]
    stop = something(findprev(==('\n'), text, prevind(text, first)), 0)
    while stop > 0
        start = something(findprev(==('\n'), text, prevind(text, stop)), 0) + 1
        content = strip(text[start:prevind(text, stop)])
        startswith(content, "#") && !startswith(content, "#=") && !startswith(content, "# corset:") || break
        pushfirst!(lines, start:(stop - 1))
        stop = start - 1
    end
    return lines
end

"""Docstring text built from comment lines `lines` of `text`, with indentation `indent`."""
function as_docstring(text::String, lines::Vector{UnitRange{Int}}, indent::String)::String
    body = [lstrip(chopprefix(lstrip(text[line]), "#")) for line in lines]
    return length(body) == 1 ? "$indent\"\"\"$(body[1])\"\"\"" :
        "$indent\"\"\"\n" * join((indent * line for line in body), "\n") * "\n$indent\"\"\""
end

"""Findings for top-level definitions under comment block, and modules without docstring."""
function run(facts::FactSet)::Vector{Finding}
    found = Finding[]
    for file in facts.files
        for definition in [nodes_named(file, "function"); nodes_named(file, "struct")]
            documented(definition) && continue
            lines = comment_lines_above(file.text, span(file, definition).first_byte)
            isempty(lines) && continue
            indent = String(match(r"^[ \t]*", file.text[lines[1]]).match)
            block = Span(file.path, first(lines[1]), last(lines[end]), Precision.exact)
            push!(
                found, finding(
                    NAME, file, definition; kind = :comment_above, confidence = Confidence.definite,
                    message = "comment above definition is not docstring", label = "definition without docstring",
                    why = "help mode, Documenter and language server show docstrings; comments stay invisible",
                    fix = Fix("turn comment into docstring", [Edit(block, as_docstring(file.text, lines, indent))], Tier.safe),
                    causes = [Label(block, "comment")],
                )
            )
        end
        for definition in nodes_named(file, "module")
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

const ENTRY = RuleEntry(NAME, Group.readability, [74, 80], Stage.syntax, run)

end
