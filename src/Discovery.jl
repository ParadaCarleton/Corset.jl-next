"""Choose files to analyze: package entry files and their include closure, like Cargo targets, or Julia files under directory."""
module Discovery

using ..Facts: SyntaxFile, BlindSpot, Role, ProjectFacts, Extension, TestDeps, include_calls, include_target, span
using ..Syntax: parse_file
using ..Config: ConfigError, parse_toml, project_root

"""
Parsed files to analyze, include calls discovery could not follow, entry files Julia loads directly,
and Project.toml facts of enclosing package (`nothing` outside project with `name`).
"""
struct Sources
    files::Vector{SyntaxFile}
    blind_spots::Vector{BlindSpot}
    entries::Vector{String}
    project::Union{Nothing, ProjectFacts}
end

"""Script entry files of package, relative to project root; analyzed when present."""
const SCRIPTS = [joinpath("test", "runtests.jl"), joinpath("docs", "make.jl"), joinpath("benchmark", "benchmarks.jl")]

"""
Sources for `path`. Package or app root (Project.toml with `name`): entry files and their include closure.
File: it and its include closure. Other directory: Julia files under it, without hidden directories and nested projects.
`environment` is project file of environment that loads package (`nothing` when run loads none); its Manifest gives `test_loads`.
"""
function discover(path::String; environment::Union{Nothing, String})::Sources
    path = abspath(path)
    root = project_root(path)
    project = isnothing(root) ? nothing : project_facts(root; environment)
    isfile(path) && return closure([path], project)
    !isnothing(project) && isfile(joinpath(path, "Project.toml")) && return closure(entry_files(project), project)
    return Sources([load(file) for file in walk_files(path)], BlindSpot[], String[], project)
end

"""Table `key` of parsed TOML `data`; empty when absent."""
table(data::AbstractDict{String, Any}, key::String)::Dict{String, Any} = get(data, key, Dict{String, Any}())

"""Package identities of dependency table `names` (name to uuid), sorted by name."""
ids(names::AbstractDict{String, Any})::Vector{Base.PkgId} = [Base.PkgId(Base.UUID(uuid), name) for (name, uuid) in sort!(collect(names); by = first)]

"""
Project.toml facts of package with project root `root`; `nothing` for project without `name`. Manifest of `environment`
project file gives `test_loads`. Config error: missing module or extension file, malformed or unknown trigger, unknown test target name.
Only package load needs uuid.
"""
function project_facts(root::String; environment::Union{Nothing, String})::Union{Nothing, ProjectFacts}
    project = parse_toml(joinpath(root, "Project.toml"))
    haskey(project, "name") || return nothing
    name = project["name"]::String
    entry = joinpath(root, "src", "$name.jl")
    isfile(entry) || throw(ConfigError("package $name has no module file src/$name.jl"))
    known = merge(table(project, "deps"), table(project, "weakdeps"))
    extensions = [extension(root, extension_name, trigger_names(extension_name, triggers), known) for (extension_name, triggers) in sort!(collect(table(project, "extensions")); by = first)]
    test_deps, tests = test_dependencies(root, project)
    uuid = tryparse(Base.UUID, string(get(project, "uuid", "")))
    loads = isnothing(uuid) || isnothing(environment) ? nothing : test_loads(environment, uuid, tests)
    return ProjectFacts(name, uuid, root, entry, ids(table(project, "deps")), extensions, test_deps, tests, loads)
end

"""
Packages that load with package `uuid` and its test dependencies `tests`: their transitive `[deps]` in Manifest of
`environment` project file, sorted by name. `nothing` when Manifest is missing or lacks package.
"""
function test_loads(environment::String, uuid::Base.UUID, tests::AbstractVector{Base.PkgId})::Union{Nothing, Vector{Base.PkgId}}
    manifest = Base.project_file_manifest_path(environment)
    isnothing(manifest) && return nothing
    entries = table(parse_toml(manifest), "deps")
    found = Dict(Base.UUID(entry["uuid"]) => (name, entry) for (name, list) in entries for entry in list)
    haskey(found, uuid) || return nothing
    pending, seen = [uuid; [test.uuid for test in tests]], Set{Base.UUID}()
    while !isempty(pending)
        next = pop!(pending)
        (next in seen || !haskey(found, next)) && continue
        push!(seen, next)
        deps = get(last(found[next]), "deps", String[])
        # Manifest lists dependency names; it maps name to uuid only where names repeat.
        append!(pending, deps isa AbstractDict ? Base.UUID.(values(deps)) : [Base.UUID(only(entries[dep])["uuid"]) for dep in deps])
    end
    return sort!([Base.PkgId(id, first(found[id])) for id in seen]; by = id -> id.name)
end

"""Trigger names of extension `name` from its `[extensions]` entry `triggers`: one name or list of names."""
function trigger_names(name::String, triggers::Any)::Vector{String}
    triggers isa String && return [triggers]
    # TOML parses list of names as `Vector{String}`; empty or mixed list as `Vector{Any}`.
    triggers isa Vector{String} && return triggers
    throw(ConfigError("extension $name needs trigger name or list of names"))
end

"""Extension `name` of package at `root` with trigger names `triggers`, looked up in `known` (`[deps]` and `[weakdeps]`)."""
function extension(root::String, name::String, triggers::AbstractVector{String}, known::AbstractDict{String, Any})::Extension
    unknown = filter(trigger -> !haskey(known, trigger), triggers)
    isempty(unknown) || throw(ConfigError("extension $name names $(join(unknown, ", ")), which [weakdeps] lacks"))
    return Extension(name, extension_file(root, name), [Base.PkgId(Base.UUID(known[trigger]), trigger) for trigger in triggers])
end

"""
Where package at `root` with parsed `project` lists test dependencies, and those not in `[deps]`.
`[targets].test` names come from `[weakdeps]` and `[extras]`; else test/Project.toml `[deps]`, without package itself.
"""
function test_dependencies(root::String, project::AbstractDict{String, Any})::Tuple{TestDeps.T, Vector{Base.PkgId}}
    deps = table(project, "deps")
    if haskey(table(project, "targets"), "test")
        known = merge(table(project, "weakdeps"), table(project, "extras"))
        names = filter(name -> !haskey(deps, name), project["targets"]["test"])
        unknown = filter(name -> !haskey(known, name), names)
        isempty(unknown) || throw(ConfigError("test target names $(join(unknown, ", ")), which [extras] lacks"))
        return TestDeps.target, ids(Dict{String, Any}(name => known[name] for name in names))
    end
    test_project = joinpath(root, "test", "Project.toml")
    isfile(test_project) || return TestDeps.none, Base.PkgId[]
    listed = filter(dep -> !haskey(deps, dep.first) && dep.first != project["name"], table(parse_toml(test_project), "deps"))
    return TestDeps.project, ids(listed)
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

"""Entry files of `project`: module file, extension files, then script entries that exist."""
entry_files(project::ProjectFacts)::Vector{String} =
    [project.entry; [extension.file for extension in project.extensions]; filter(isfile, [joinpath(project.root, script) for script in SCRIPTS])]

"""File of extension `name`: `ext/<name>.jl`, else `ext/<name>/<name>.jl`, as Julia loads it."""
function extension_file(root::String, name::String)::String
    flat, nested = joinpath(root, "ext", "$name.jl"), joinpath(root, "ext", name, "$name.jl")
    isfile(flat) && return flat
    isfile(nested) || throw(ConfigError("extension $name has no file ext/$name.jl or ext/$name/$name.jl"))
    return nested
end

"""Parse `entries` of `project` and every file they include, breadth first; include calls not followed become blind spots."""
function closure(entries::AbstractVector{String}, project::Union{Nothing, ProjectFacts})::Sources
    paths = collect(String, entries)
    files, blind_spots, pending, seen = SyntaxFile[], BlindSpot[], copy(paths), Set{String}()
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
    return Sources(files, blind_spots, paths, project)
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
