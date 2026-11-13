"""Choose files to analyze: package entry files and their include closure, like Cargo targets, or Julia files under directory."""
module Discovery

using ..Facts: SyntaxFile, BlindSpot, Role, include_calls, include_target, span
using ..Syntax: parse_file
using ..Config: ConfigError, parse_toml, project_root

"""Parsed files to analyze, include calls discovery could not follow, and entry files Julia loads directly."""
struct Sources
    files::Vector{SyntaxFile}
    blind_spots::Vector{BlindSpot}
    entries::Vector{String}
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
    return Sources([load(file) for file in walk_files(path)], BlindSpot[], String[])
end

"""Parsed file at `path` with its role."""
load(path::String)::SyntaxFile = parse_file(path, read(path, String), role_of(path))

"""Role of file at `path`: `package` under `src` or `ext` of project with `name`, which precompiles; else `script`."""
function role_of(path::String)::Role.T
    root = project_root(path)
    (isnothing(root) || !haskey(parse_toml(joinpath(root, "Project.toml")), "name")) && return Role.script
    parts = splitpath(relpath(path, root))
    return length(parts) > 1 && parts[1] in ("src", "ext") ? Role.package : Role.script
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
        file = load(path)
        push!(files, file)
        for call in include_calls(file)
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
    return Sources(files, blind_spots, entries)
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
