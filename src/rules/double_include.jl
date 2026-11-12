"""`double-include` (F64): same file included twice defines everything in it twice."""
module DoubleInclude

using ...Facts

const NAME = Symbol("double-include")
const PATTERN = IndexedPattern(@pattern include({path}))

"""Literal path of `include` argument, resolved against including file; `nothing` for computed path."""
function included_path(file::SyntaxFile, argument)::Union{Nothing, String}
    kind_name(argument) == "string" || return nothing
    parts = children_of(argument)
    length(parts) == 1 && kind_name(parts[1]) == "String" || return nothing
    return normpath(joinpath(dirname(file.path), leaf_value(parts[1])))
end

"""Findings for second and later `include` of same literal path across run."""
function run(facts::FactSet)::Vector{Finding}
    first_seen = Dict{String, Label}()
    found = Finding[]
    for file in facts.files, match in matches(file, PATTERN)
        path = included_path(file, binding(match, :path))
        isnothing(path) && continue
        if !haskey(first_seen, path)
            first_seen[path] = Label(span(file, match.node), "first included here")
            continue
        end
        push!(
            found, finding(
                NAME, file, match.node; kind = :repeated_include, confidence = Confidence.definite,
                message = "`$(source(file, match.node))` includes file again", label = "second copy of every definition",
                why = "methods are redefined and structs error or shadow; load order then decides behavior",
                fix = manual_fix("include each file once, from package entry file"), causes = [first_seen[path]],
            )
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [64], Stage.syntax, run)

end
