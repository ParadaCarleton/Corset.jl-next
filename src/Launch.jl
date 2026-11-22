"""
Command-line relaunch: build temporary environment for target package, then run command line again inside it.

Environment is nameless project that starts from target Manifest, develops target and Corset by path, and adds test dependencies.
Every target Manifest version stays when Corset accepts it. Otherwise packages Corset shares with target move, fewest first;
build prints each move, and relaunched process counts it as blind spot. Resolution that still fails is config error.
Relaunched process loads only from that environment and `@stdlib`, so default environment adds no package, trigger or method.
"""
module Launch

using FileWatching.Pidfile: PidlockedError, mkpidlock
using Base.ScopedValues: @with
using Pkg: Pkg
using Scratch: get_scratch!
using SHA: sha256
using TOML: TOML
using ..Config: ConfigError, parse_toml
using ..Facts: ProjectFacts, TestDeps
using ..Package: package_id
using ..Inference: records, last_crash, log_file

"""Load path of relaunched process: active project, then standard library."""
const LOAD_PATH = "@:@stdlib"

"""
Code relaunched process runs: same command line, without relaunch, with cache directory `cache` of relaunching process
and crash `journal` directory.
"""
child(cache::Union{Nothing, String}, journal::String)::String =
    "using Corset: Corset; exit(Corset.CLI.execute(ARGS, stdout, stderr; launch = false, cache = $(repr(cache)), journal = $(repr(journal))))"

"""`Base.load_path()` of process that `relaunch` starts in `env`: `LOAD_PATH` expanded."""
load_path(env::String)::Vector{String} = [joinpath(env, "Project.toml"), Sys.STDLIB]

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

"""Spec of test dependency `id`; `source` is its `[sources]` entry in test/Project.toml, read relative to `directory`."""
function source_spec(id::Base.PkgId, source::Union{Nothing, Dict{String, Any}}, directory::String)::Pkg.PackageSpec
    name, uuid = id.name, id.uuid
    isnothing(source) && return Pkg.PackageSpec(; name, uuid)
    haskey(source, "path") && return Pkg.PackageSpec(; name, uuid, path = abspath(directory, source["path"]))
    return Pkg.PackageSpec(; name, uuid, url = get(source, "url", nothing), rev = get(source, "rev", nothing), subdir = get(source, "subdir", nothing))
end

"""
Specs of test dependencies of `project`, at path or repository `[sources]` gives: test/Project.toml for its own list,
else Project.toml. Corset is left out: environment develops running Corset instead.
"""
function test_specs(project::ProjectFacts)::Vector{Pkg.PackageSpec}
    directory = project.test_deps == TestDeps.project ? joinpath(project.root, "test") : project.root
    sources = get(parse_toml(joinpath(directory, "Project.toml")), "sources", Dict{String, Any}())
    corset = Base.PkgId(Base.moduleroot(@__MODULE__))
    return [source_spec(id, get(sources, id.name, nothing), directory) for id in project.tests if id != corset]
end

"""Root directory of Corset package this process runs."""
corset_root()::String = pkgdir(Base.moduleroot(@__MODULE__))

"""
Cache key of environment for package of `project`: hash of target path, Corset path, Julia version and files that shape
environment. Those include Project.toml of each path dependency: Manifest entry or test `[sources]` entry.
"""
function cache_key(project::ProjectFacts)::String
    root, file = project.root, joinpath(project.root, "Project.toml")
    paths = String[entry["path"] for entries in values(manifest_deps(file)) for entry in entries if haskey(entry, "path")]
    append!(paths, [spec.path for spec in test_specs(project) if !isnothing(spec.path)])
    dependencies = [joinpath(path, "Project.toml") for path in sort!(unique!(paths))]
    files = [file; something(Base.project_file_manifest_path(file), ""); joinpath(root, "LocalPreferences.toml"); joinpath(root, "test", "Project.toml"); joinpath(corset_root(), "Project.toml"); dependencies]
    parts = [realpath(root); realpath(corset_root()); string(VERSION); [isfile(file) ? read(file, String) : "" for file in files]]
    return bytes2hex(sha256(join(parts, '\0')))[1:16]
end

"""
Package sets relaunch may move off target Manifest version, in order tried: none, then Corset direct dependencies,
then every package this process loaded. Corset loads its dependencies at start, so last set holds its dependency closure.
"""
function unpin_tiers()::Vector{Set{Base.UUID}}
    direct = Set{Base.UUID}(Base.UUID(uuid) for uuid in values(parse_toml(joinpath(corset_root(), "Project.toml"))["deps"]))
    loaded = Set{Base.UUID}(id.uuid for id in keys(Base.loaded_modules) if !isnothing(id.uuid))
    return [Set{Base.UUID}(), direct, union(direct, loaded)]
end

"""Uuids of Manifest entries `deps` that `free` holds."""
freed(deps::Dict{String, Any}, free::Set{Base.UUID})::Set{Base.UUID} =
    Set{Base.UUID}(uuid for entries in values(deps) for entry in entries for uuid in (Base.UUID(entry["uuid"]),) if uuid in free)

"""
Write Project.toml and Manifest.toml of `env` from target Manifest entries `deps`. Project.toml lists each versioned entry
outside `free` as direct dependency, so `PRESERVE_DIRECT` keeps its version. Name with two entries stays unlisted.
"""
function write_env!(env::String, preferences::Dict{String, Any}, deps::Dict{String, Any}, free::Set{Base.UUID})::Nothing
    kept = Dict{String, Any}(name => only(entries)["uuid"] for (name, entries) in deps if length(entries) == 1 && haskey(only(entries), "version") && Base.UUID(only(entries)["uuid"]) ∉ free)
    open(io -> TOML.print(io, Dict("preferences" => preferences, "deps" => kept)), joinpath(env, "Project.toml"), "w")
    open(io -> TOML.print(io, Dict("manifest_format" => "2.0", "deps" => deps)), joinpath(env, "Manifest.toml"), "w")
    return nothing
end

"""Versions that Manifest entries `used` give packages of `pinned` in place of pinned version: name, pinned, used; sorted."""
function moves(pinned::Dict{String, Any}, used::Dict{String, Any})::Vector{Tuple{String, String, String}}
    versions = Dict(entry["uuid"] => entry["version"] for entries in values(used) for entry in entries if haskey(entry, "version"))
    moved = [(name, entry["version"], get(versions, entry["uuid"], entry["version"])) for (name, entries) in pinned for entry in entries if haskey(entry, "version")]
    return sort!(filter(((_, from, to),) -> from != to, moved))
end

"""
Pkg preserve level of build attempt that frees `uuids` of target Manifest entries `deps`. Without Manifest nothing is
pinned: resolver may move version that `develop` picked before test dependencies joined.
"""
preserve_level(deps::Dict{String, Any}, uuids::Set{Base.UUID})::Pkg.PreserveLevel =
    isempty(deps) ? Pkg.PRESERVE_TIERED : isempty(uuids) ? Pkg.PRESERVE_ALL : Pkg.PRESERVE_DIRECT

"""
Build temporary environment for package of `project` in empty directory `env`; return Manifest versions it moved.
Each set of `tiers` frees its packages; first set that resolves wins. Set that frees no new Manifest entry is skipped.
"""
function build!(env::String, project::ProjectFacts, tiers::Vector{Set{Base.UUID}})::Vector{Tuple{String, String, String}}
    root = project.root
    preferences = get(parse_toml(joinpath(root, "Project.toml")), "preferences", Dict{String, Any}())
    deps = manifest_deps(joinpath(root, "Project.toml"))
    local_preferences = joinpath(root, "LocalPreferences.toml")
    isfile(local_preferences) && cp(local_preferences, joinpath(env, "LocalPreferences.toml"))
    develop = [Pkg.PackageSpec(; path) for path in unique!([realpath(root), realpath(corset_root())])]
    tests = test_specs(project)
    local_tests, registered = filter(spec -> !isnothing(spec.path), tests), filter(spec -> isnothing(spec.path), tests)
    failures, tried = Exception[], Set{Set{Base.UUID}}()
    for free in tiers
        uuids = freed(deps, free)
        uuids in tried && continue
        push!(tried, uuids)
        write_env!(env, preferences, deps, uuids)
        preserve = preserve_level(deps, uuids)
        try
            # Relaunched process precompiles what it loads. Pkg's task-local switch leaves process environment alone.
            # Barriers: method that target adds (`promote_rule`) invalidates Pkg internals, and would take caller too.
            @with Pkg._autoprecompilation_enabled_scoped => false Pkg.activate(env) do
                Base.inferencebarrier(Pkg.develop)(develop; preserve, io = devnull)
                isempty(local_tests) || Base.inferencebarrier(Pkg.develop)(local_tests; preserve, io = devnull)
                isempty(registered) || Base.inferencebarrier(Pkg.add)(registered; preserve, io = devnull)
            end
            return moves(deps, manifest_deps(joinpath(env, "Project.toml")))
        catch error
            error isa Pkg.Types.PkgError || error isa Pkg.Resolve.ResolverError || rethrow()
            push!(failures, error)
        end
    end
    throw(ConfigError("cannot build environment for $(project.name) from its Manifest, even with Corset dependencies moved: $(sprint(showerror, last(failures)))"))
end

"""
Seconds after which lock of dead process on this host counts as stale. Live holder refreshes lock every half of this;
lock of live or other-host process goes stale only after 5 times this.
"""
const LOCK_STALE_SECONDS = 30

"""Run `body` under pidfile lock at `path`. Stale lock clears at once; lock of live run is waited for."""
function locked(body::Function, path::String)::Nothing
    pidlock = try
        mkpidlock(path; stale_age = LOCK_STALE_SECONDS, wait = false)
    catch error
        error isa PidlockedError || rethrow()
        # Waiting attempt checks staleness only after it waits `stale_age` seconds.
        mkpidlock(path; stale_age = LOCK_STALE_SECONDS)
    end
    try
        body()
    finally
        close(pidlock)
    end
    return nothing
end

"""Cached temporary environment for package of `project`; build it first when missing, with note to `err`."""
function environment(project::ProjectFacts, err::IO)::String
    # Pkg cannot develop package without uuid: fail before build with clear error.
    id = package_id(project)
    cache = get_scratch!(Base.moduleroot(@__MODULE__), "environments")
    env = joinpath(cache, cache_key(project))
    locked("$env.pid") do
        isdir(env) && return
        println(err, "corset: building environment for $(id.name); later runs reuse it")
        # Relaunched process writes to same stream; note must come first.
        flush(err)
        mktempdir(cache) do staging
            for (name, from, to) in build!(staging, project, unpin_tiers())
                println(err, "corset: Manifest pins $name $from; environment uses $to, which Corset needs")
            end
            flush(err)
            mv(staging, env)
        end
    end
    return env
end

"""
Command `julia` with coverage and allocation tracking off. `Base.julia_cmd()` copies both flags from running process;
later flag wins, so relaunched process writes no `.cov` or `.mem` files into trees that cache key hashes.
"""
untracked(julia::Cmd)::Cmd = `$julia --code-coverage=none --track-allocation=none`

"""
Finished Julia process that ran command line `args` again with cache directory `cache` and crash `journal` directory,
loading only from `env` and `@stdlib`.
"""
function relaunch(env::String, args::Vector{String}, cache::Union{Nothing, String}, journal::String, out::IO, err::IO)::Base.Process
    command = `$(untracked(Base.julia_cmd())) --startup-file=no --project=$env -e $(child(cache, journal)) -- $args`
    return run(pipeline(ignorestatus(addenv(command, "JULIA_LOAD_PATH" => LOAD_PATH)); stdout = out, stderr = err))
end

"""Most crashes one run survives; each costs one more package load."""
const CRASHES = 32

"""
Last relaunched process of run `relaunch` starts: process that native abort kills during inference runs again, and
journal makes that run skip crashed inference. Prints note per crash to `err`; throws after `limit` crashes. Journal
directory stays when note names its crash log. Julia exception never reruns.
"""
function supervise(env::String, args::Vector{String}, cache::Union{Nothing, String}, out::IO, err::IO, limit::Int)::Base.Process
    journal = mktempdir(get_scratch!(Base.moduleroot(@__MODULE__), "crashes"); cleanup = false)
    for crashes in 0:limit
        process = relaunch(env, args, cache, journal, out, err)
        crash = process.termsignal == 0 ? nothing : last_crash(records(journal))
        if isnothing(crash)
            crashes == 0 && rm(journal; recursive = true)
            return process
        end
        println(err, "corset: Julia crashed inferring ", crash.label, "; running again without it (blind spot). Report: ", log_file(journal))
    end
    error("relaunched process crashed $(limit + 1) times, over limit $limit; reports in $(log_file(journal))")
end

end
