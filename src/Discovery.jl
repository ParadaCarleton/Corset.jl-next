"""Choose files to analyze: package entry files and their include closure, like Cargo targets, or Julia files under directory."""
module Discovery

using ..Facts: SyntaxFile, BlindSpot, forms, call_head, children_of, kind_name, leaf_value, span
using ..Syntax: parse_file
using ..Config: ConfigError, parse_toml

"""Parsed files to analyze, and include calls discovery could not follow."""
struct Sources
    files::Vector{SyntaxFile}
    blind_spots::Vector{BlindSpot}
end

"""Script entry files of package, relative to project root; analyzed when present."""
const SCRIPTS = [joinpath("test", "runtests.jl"), joinpath("docs", "make.jl"), joinpath("benchmark", "benchmarks.jl")]

"""
Sources for `path`. Package or app root (Project.toml with `name`): entry files and their include closure.
File: it and its include closure. Other directory: Julia files under it, without hidden directories and nested projects.
"""
function discover(path::String)::Sources
    path = abspath(path)
    isfile(path) && return closure([path])
    project_file = joinpath(path, "Project.toml")
    project = isfile(project_file) ? parse_toml(project_file) : Dict{String, Any}()
    haskey(project, "name") && return closure(entry_files(path, project))
    return Sources([parse_file(file, read(file, String)) for file in walk_files(path)], BlindSpot[])
end

"""Entry files of package at `root`: module file, extension files, then script entries that exist."""
function entry_files(root::String, project::Dict{String, Any})::Vector{String}
    name = project["name"]::String
    main = joinpath(root, "src", "$name.jl")
    isfile(main) || throw(ConfigError("package $name has no module file src/$name.jl"))
    extensions = [extension_file(root, extension) for extension in sort!(collect(keys(get(project, "extensions", Dict{String, Any}()))))]
    return [main; extensions; filter(isfile, [joinpath(root, script) for script in SCRIPTS])]
end

"""File of extension `name`: `ext/<name>.jl`, else `ext/<name>/<name>.jl`, as Julia loads it."""
function extension_file(root::String, name::String)::String
    flat, nested = joinpath(root, "ext", "$name.jl"), joinpath(root, "ext", name, "$name.jl")
    isfile(flat) && return flat
    isfile(nested) || throw(ConfigError("extension $name has no file ext/$name.jl or ext/$name/$name.jl"))
    return nested
end

"""Parse `entries` and every file they include, breadth first; include calls not followed become blind spots."""
function closure(entries::Vector{String})::Sources
    files, blind_spots, pending, seen = SyntaxFile[], BlindSpot[], copy(entries), Set{String}()
    while !isempty(pending)
        path = popfirst!(pending)
        path in seen && continue
        push!(seen, path)
        file = parse_file(path, read(path, String))
        push!(files, file)
        for call in forms(file, "call")
            call_head(call) == "include" || continue
            target = include_target(file, call)
            if isnothing(target)
                push!(blind_spots, BlindSpot("include with computed path", span(file, call)))
            elseif !isfile(target)
                push!(blind_spots, BlindSpot("include of missing file", span(file, call)))
            else
                push!(pending, target)
            end
        end
    end
    return Sources(files, blind_spots)
end

"""Absolute path that include `call` in `file` loads; `nothing` when path is computed."""
function include_target(file::SyntaxFile, call)::Union{Nothing, String}
    parts = path_parts(file, children_of(call)[end])
    return isnothing(parts) ? nothing : normpath(joinpath(dirname(file.path), parts...))
end

"""Path pieces of `node`: string literal, `@__DIR__`, or `joinpath` of those; `nothing` for anything else."""
function path_parts(file::SyntaxFile, node)::Union{Nothing, Vector{String}}
    pieces = children_of(node)
    kind_name(node) == "string" && length(pieces) == 1 && kind_name(pieces[1]) == "String" && return [leaf_value(pieces[1])]
    kind_name(node) == "macrocall" && leaf_value(pieces[1]) == "@__DIR__" && return [dirname(file.path)]
    call_head(node) == "joinpath" || return nothing
    parts = [path_parts(file, piece) for piece in pieces[2:end]]
    return any(isnothing, parts) ? nothing : reduce(vcat, parts; init = String[])
end

"""Julia files under `directory`, sorted; skips hidden directories, symbolic links and directories with own Project.toml."""
function walk_files(directory::String)::Vector{String}
    found = String[]
    for name in sort!(readdir(directory))
        path = joinpath(directory, name)
        if isdir(path)
            startswith(name, ".") || islink(path) || isfile(joinpath(path, "Project.toml")) || append!(found, walk_files(path))
        elseif endswith(name, ".jl")
            push!(found, path)
        end
    end
    return found
end

end
