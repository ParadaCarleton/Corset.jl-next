"""
Command-line relaunch: build temporary environment for target package, then run command line again inside it.

Environment is nameless project that starts from target Manifest, develops target and Corset by path, and adds test dependencies.
Every target Manifest version stays; resolution that needs other version is config error.
Relaunched process loads only from that environment and `@stdlib`, so default environment adds no package, trigger or method.
"""
module Launch

using FileWatching.Pidfile: mkpidlock
using Base.ScopedValues: @with
using Pkg: Pkg
using Scratch: get_scratch!
using SHA: sha256
using TOML: TOML
using ..Config: ConfigError, parse_toml

"""Load path of relaunched process: active project, then standard library."""
const LOAD_PATH = "@:@stdlib"

"""Code relaunched process runs: same command line, without relaunch."""
const CHILD = "using Corset: Corset; exit(Corset.CLI.execute(ARGS, stdout, stderr; launch = false))"

"""Package specs of Manifest entries of project file `project`, with relative paths made absolute; empty without Manifest."""
function manifest_deps(project::String)::Dict{String, Any}
    manifest = Base.project_file_manifest_path(project)
    isnothing(manifest) && return Dict{String, Any}()
    data = parse_toml(manifest)
    haskey(data, "manifest_format") || throw(ConfigError("$manifest has format 1; run `Pkg.upgrade_manifest()` in its environment"))
    deps = get(data, "deps", Dict{String, Any}())
    for entries in values(deps), entry in entries
        haskey(entry, "path") && (entry["path"] = abspath(dirname(manifest), entry["path"]))
    end
    return deps
end

"""Spec of dependency `name` with `uuid`; `source` is its `[sources]` entry, read relative to `directory`."""
function source_spec(name::String, uuid::String, source::Union{Nothing, Dict{String, Any}}, directory::String)::Pkg.PackageSpec
    isnothing(source) && return Pkg.PackageSpec(; name, uuid = Base.UUID(uuid))
    haskey(source, "path") && return Pkg.PackageSpec(; name, uuid = Base.UUID(uuid), path = abspath(directory, source["path"]))
    return Pkg.PackageSpec(; name, uuid = Base.UUID(uuid), url = source["url"], rev = get(source, "rev", nothing))
end

"""Test dependencies of package at `root`, other than target `id`: `[targets].test` names, else `test/Project.toml` deps."""
function test_specs(root::String, id::Base.PkgId)::Vector{Pkg.PackageSpec}
    project = parse_toml(joinpath(root, "Project.toml"))
    test_project = joinpath(root, "test", "Project.toml")
    if haskey(get(project, "targets", Dict{String, Any}()), "test")
        deps = get(project, "deps", Dict{String, Any}())
        known = merge(get(project, "weakdeps", Dict{String, Any}()), get(project, "extras", Dict{String, Any}()))
        names = filter(name -> !haskey(deps, name), project["targets"]["test"])
        unknown = filter(name -> !haskey(known, name), names)
        isempty(unknown) || throw(ConfigError("test target names $(join(unknown, ", ")), which [extras] lacks"))
        return [Pkg.PackageSpec(; name, uuid = Base.UUID(known[name])) for name in names]
    end
    isfile(test_project) || return Pkg.PackageSpec[]
    tests = parse_toml(test_project)
    sources = get(tests, "sources", Dict{String, Any}())
    deps = filter(dep -> Base.UUID(dep.second) != id.uuid, get(tests, "deps", Dict{String, Any}()))
    return [source_spec(name, uuid, get(sources, name, nothing), dirname(test_project)) for (name, uuid) in sort!(collect(deps))]
end

"""Root directory of Corset package this process runs."""
corset_root()::String = pkgdir(Base.moduleroot(@__MODULE__))

"""Cache key of environment for package at `root`: hash of target path, Corset path, Julia version and files that shape environment."""
function cache_key(root::String)::String
    project = joinpath(root, "Project.toml")
    files = [project, something(Base.project_file_manifest_path(project), ""), joinpath(root, "LocalPreferences.toml"), joinpath(root, "test", "Project.toml"), joinpath(corset_root(), "Project.toml")]
    parts = [realpath(root); realpath(corset_root()); string(VERSION); [isfile(file) ? read(file, String) : "" for file in files]]
    return bytes2hex(sha256(join(parts, '\0')))[1:16]
end

"""Build temporary environment for package `id` at `root` in empty directory `env`."""
function build!(env::String, root::String, id::Base.PkgId)::Nothing
    project = parse_toml(joinpath(root, "Project.toml"))
    preferences = get(project, "preferences", Dict{String, Any}())
    open(io -> TOML.print(io, Dict("preferences" => preferences)), joinpath(env, "Project.toml"), "w")
    manifest = Dict("manifest_format" => "2.0", "deps" => manifest_deps(joinpath(root, "Project.toml")))
    open(io -> TOML.print(io, manifest), joinpath(env, "Manifest.toml"), "w")
    local_preferences = joinpath(root, "LocalPreferences.toml")
    isfile(local_preferences) && cp(local_preferences, joinpath(env, "LocalPreferences.toml"))
    develop = unique!([realpath(root), realpath(corset_root())])
    tests = test_specs(root, id)
    try
        # Relaunched process precompiles what it loads. Pkg's task-local switch leaves process environment alone.
        @with Pkg._autoprecompilation_enabled_scoped => false Pkg.activate(env) do
            Pkg.develop([Pkg.PackageSpec(; path) for path in develop]; preserve = Pkg.PRESERVE_ALL, io = devnull)
            local_tests = filter(spec -> !isnothing(spec.path), tests)
            isempty(local_tests) || Pkg.develop(local_tests; preserve = Pkg.PRESERVE_ALL, io = devnull)
            registered = filter(spec -> isnothing(spec.path), tests)
            isempty(registered) || Pkg.add(registered; preserve = Pkg.PRESERVE_ALL, io = devnull)
        end
    catch error
        error isa Pkg.Types.PkgError || error isa Pkg.Resolve.ResolverError || rethrow()
        throw(ConfigError("cannot build environment for $(id.name) that keeps every Manifest version: $(sprint(showerror, error))"))
    end
    return nothing
end

"""Cached temporary environment for package `id` at `root`; build it first when missing, with note to `err`."""
function environment(root::String, id::Base.PkgId, err::IO)::String
    cache = get_scratch!(Base.moduleroot(@__MODULE__), "environments")
    env = joinpath(cache, cache_key(root))
    mkpidlock("$env.pid") do
        isdir(env) && return
        println(err, "corset: building environment for $(id.name); later runs reuse it")
        mktempdir(cache) do staging
            build!(staging, root, id)
            mv(staging, env)
        end
    end
    return env
end

"""Finished Julia process that ran command line `args` again, loading only from `env` and `@stdlib`."""
function relaunch(env::String, args::Vector{String}, out::IO, err::IO)::Base.Process
    command = `$(Base.julia_cmd()) --startup-file=no --project=$env -e $CHILD -- $args`
    return run(pipeline(ignorestatus(addenv(command, "JULIA_LOAD_PATH" => LOAD_PATH)); stdout = out, stderr = err))
end

end
