"""
Disk cache of analyses: one entry per checked path, holding key and stored analysis. Key hashes every analysis input,
so changed input misses and run analyzes again. Library summaries of `effects` stage share one library file per
partition (`partition_key`), whose entries every checked path and environment shares.
"""
module Cache

using Serialization: serialize, deserialize
using SHA: SHA, sha256
using Scratch: get_scratch!
using TOML: TOML
using ..Launch: corset_root

"""Cache directory of command line: scratch space of Corset in Julia depot. CI that saves depot keeps it."""
directory()::String = get_scratch!(Base.moduleroot(@__MODULE__), "analyses")

"""
Files under `root`, sorted. Names that start with dot stay out, with everything below them; so does directory `cache`,
whose entries would change key they are stored under.
"""
function tree_files(root::String, cache::String)::Vector{String}
    files = String[]
    for (directory, directories, names) in walkdir(root)
        filter!(name -> !startswith(name, '.') && joinpath(directory, name) != cache, directories)
        # Symbolic link to directory arrives in `names`; `isfile` drops it.
        kept = [joinpath(directory, name) for name in names if !startswith(name, '.')]
        append!(files, filter(isfile, kept))
    end
    return sort!(files)
end

"""
Directories of `path` entries in Manifest of project file `environment`, made absolute. Reads Manifest format 1 too:
any environment can sit on load path, and old format must not break run.
"""
function path_entries(environment::String)::Vector{String}
    manifest = Base.project_file_manifest_path(environment)
    isnothing(manifest) && return String[]
    deps = Base.get_deps(TOML.parsefile(manifest))
    return [abspath(dirname(manifest), entry["path"]) for entries in values(deps) for entry in entries if haskey(entry, "path")]
end

"""Add `text` to `context` with its length first, so neighboring parts cannot run together."""
function update_part!(context::SHA.SHA256_CTX, text::String)::Nothing
    SHA.update!(context, codeunits(string(sizeof(text), ':')))
    SHA.update!(context, codeunits(text))
    return nothing
end

"""
Text parts and files that key of analysis of checked `path` with `flags` text hashes. Parts: Julia version, cache flags,
`path`, `flags` and each environment of `load_path`. Files: analyzed `files`, Corset source, each project environment
with its Manifest and preferences, and every file of project root `root` and of Manifest `path` entries, `cache`
directory left out.
"""
function inputs(path::String, flags::String, root::Union{Nothing, String}, files::Vector{String}, load_path::Vector{String}, cache::String)::Tuple{Vector{String}, Vector{String}}
    parts, listed, trees = environment_inputs(load_path)
    return [string(VERSION), repr(Base.CacheFlags()), path, flags, parts...], found_files([files; listed], [trees; something(root, String[])], cache)
end

"""
Environment parts of key: each environment of `load_path`. Files: Corset project file, and each project environment
with its Manifest and preferences. Trees: Corset source and Manifest `path` entries.
"""
function environment_inputs(load_path::Vector{String})::Tuple{Vector{String}, Vector{String}, Vector{String}}
    corset = corset_root()
    parts, listed, trees = String[], [joinpath(corset, "Project.toml")], [joinpath(corset, "src")]
    for environment in load_path
        push!(parts, environment)
        # Directory environment, such as standard library, counts by path.
        isfile(environment) || continue
        directory = dirname(environment)
        append!(listed, [environment; something(Base.project_file_manifest_path(environment), String[]); joinpath.(directory, ["LocalPreferences.toml", "JuliaLocalPreferences.toml"])])
        append!(trees, path_entries(environment))
    end
    return parts, listed, trees
end

"""`listed` files and every file of `trees`, `cache` directory left out, by real path and sorted."""
function found_files(listed::Vector{String}, trees::Vector{String}, cache::String)::Vector{String}
    # Stale `path` entry names directory that is gone; it adds no file.
    found = [listed; (tree_files(tree, cache) for tree in unique(trees) if isdir(tree))...]
    # Processes that reach file through other links must agree, so files count by real path.
    return sort!(unique!([ispath(file) ? realpath(file) : file for file in found]))
end

"""
Key line of method store of checked `path`: Julia version, cache flags, `path`, environment (`environment_inputs`),
analyzed `files` by path, package `shape`, and files of project `root` that package code loads from (`src`, `ext`,
`deps`) but `files` leave out. Store entries count analyzed files by content, so Manifest `path` entry of `root` stays out.
"""
function method_key(path::String, root::String, files::Vector{String}, shape::Vector{String}, load_path::Vector{String}, cache::String)::String
    parts, listed, trees = environment_inputs(load_path)
    root = realpath(root)
    kept = [filter(tree -> !(ispath(tree) && realpath(tree) == root), trees); joinpath.(root, ["src", "ext", "deps"])]
    analyzed = Set(ispath(file) ? realpath(file) : file for file in files)
    outside = filter(file -> !(file in analyzed), found_files(listed, kept, cache))
    return digest([string(VERSION), repr(Base.CacheFlags()), path, parts..., files..., shape...], outside)
end

"""SHA-256 of `parts`, then of path and content of each of `files`. Missing file counts too: file that appears changes digest."""
function digest(parts::Vector{String}, files::Vector{String})::String
    context = SHA.SHA256_CTX()
    foreach(part -> update_part!(context, part), parts)
    for file in files
        update_part!(context, file)
        update_part!(context, isfile(file) ? bytes2hex(sha256(read(file))) : "absent")
    end
    return bytes2hex(SHA.digest!(context))
end

"""Key of analysis: digest of `inputs`."""
key(path::String, flags::String, root::Union{Nothing, String}, files::Vector{String}, load_path::Vector{String}, cache::String)::String =
    digest(inputs(path, flags, root, files, load_path, cache)...)

"""
Content text of package `id` at `root` for library entry key: name, UUID, then `root` for package in standard library
or in `packages` directory of one of `depots`, whose slug Pkg derives from Manifest tree hash. Path or developed package
gives digest of its code files instead: project file, `src`, `ext` and `deps`. Preferences of package count too.
"""
function package_content(id::Base.PkgId, root::String, depots::Vector{String})::String
    stores = [Sys.STDLIB; [joinpath(depot, "packages") for depot in depots]]
    fixed = any(store -> startswith(root, joinpath(store, "")), stores)
    content = fixed ? root : digest(String[], found_files([joinpath(root, "Project.toml")], joinpath.(root, ["src", "ext", "deps"]), ""))
    preferences = Base.get_preferences(id.uuid)
    return "$(id.name) $(id.uuid) $content" * (isempty(preferences) ? "" : "\n" * sprint(io -> TOML.print(io, preferences; sorted = true)))
end

"""
Content texts that inference of code in module `mod` depends on (`effects.md`, Solve and cache): none for Base and
Core, as Julia version covers them; else content of its package (`package_content`) and texts of each loaded package
it depends on. Corset gives texts of its dependencies only, as partition key holds its content. Extension depends on its
parent and triggers. `nothing` for module without package root on disk, such as `Main`. `texts` caches answers by root
module.
"""
function owner_texts!(texts::IdDict{Module, Union{Nothing, Vector{String}}}, mod::Module, depots::Vector{String})::Union{Nothing, Vector{String}}
    root = Base.moduleroot(mod)
    (root === Base || root === Core) && return String[]
    haskey(texts, root) && return texts[root]
    # Placeholder answers cycle, which package loading forbids.
    texts[root] = nothing
    id = Base.PkgId(root)
    extension = haskey(Base.EXT_PRIMED, id)
    directory = pkgdir(root)
    isnothing(id.uuid) && return nothing
    extension || (!isnothing(directory) && isdir(directory)) || return nothing
    dependencies = extension ? Base.EXT_PRIMED[id] : dependency_ids(something(directory))
    isnothing(dependencies) && return nothing
    found = extension || root === Base.moduleroot(@__MODULE__) ? String[] : [package_content(id, something(directory), depots)]
    for dependency in dependencies
        # Dependency that is not loaded cannot change loaded code.
        Base.root_module_exists(dependency) || continue
        inherited = owner_texts!(texts, Base.root_module(dependency), depots)
        isnothing(inherited) && return nothing
        append!(found, inherited)
    end
    return texts[root] = sort!(unique!(found))
end

"""Packages in `deps` of project file at package `root`; `nothing` without project file."""
function dependency_ids(root::String)::Union{Nothing, Vector{Base.PkgId}}
    project = findfirst(isfile, joinpath.(root, Base.project_names))
    isnothing(project) && return nothing
    deps = get(TOML.parsefile(joinpath(root, Base.project_names[project])), "deps", Dict{String, Any}())
    return [Base.PkgId(Base.UUID(uuid), name) for (name, uuid) in deps]
end

"""Library directory of cache `directory`: one library file per partition (`partition_key`)."""
library_directory(directory::String)::String = joinpath(directory, "library")

"""
Partition key of library file: Julia version `julia`, cache flags and content of Corset (`package_content`) under
`depots`. Entry keys hold all else.
"""
function partition_key(julia::String, depots::Vector{String})::String
    corset = Base.moduleroot(@__MODULE__)
    return digest([julia, repr(Base.CacheFlags()), package_content(Base.PkgId(corset), corset_root(), depots)], String[])
end

"""
Library cache entry: instance key of instance it describes (`Effects.instance_key!`), serialized value, and time of
last write or hit, which prune order reads.
"""
struct Stamped
    instance::String
    bytes::Vector{UInt8}
    used::Float64
end

"""Library files that library directory keeps, newest first: files of other Julia or Corset versions drop out."""
const LIBRARY_FILES = 4

"""Entry bytes that library file keeps at most (`keep_library!`)."""
const LIBRARY_BYTES = 128 * 2^20

"""Entries of library file of `partition` in library `directory`; none when file is missing or has other key."""
read_library(directory::String, partition::String)::Dict{String, Stamped} = something(lookup(Dict{String, Stamped}, directory, partition, partition), Dict{String, Stamped}())

"""
Merge `found` entries into library file of `partition` in library `directory`, read again just before write. Found
entries and `hits` take time now. Then entries go newest first while their bytes stay within `limit`. Run without found
entries writes no entries: it marks file as used. Directory keeps newest `LIBRARY_FILES` files; staging files of other
processes stay. Concurrent writer can lose entries of other, but file changes in one step.
"""
function keep_library!(directory::String, partition::String, found::Dict{String, Stamped}, hits::Set{String}, limit::Int)::Nothing
    file = entry(directory, partition)
    if isempty(found)
        isfile(file) || return nothing
        touch(file)
    else
        entries, now = read_library(directory, partition), time()
        restamp(stamped::Stamped)::Stamped = Stamped(stamped.instance, stamped.bytes, now)
        foreach(key -> haskey(entries, key) && (entries[key] = restamp(entries[key])), hits)
        foreach(((key, stamped),) -> entries[key] = restamp(stamped), found)
        kept, total = Dict{String, Stamped}(), 0
        # Key breaks ties of time, so processes agree on kept entries.
        for (key, stamped) in sort!(collect(entries); by = ((key, stamped),) -> (-stamped.used, key))
            total += length(stamped.bytes)
            total > limit && break
            kept[key] = stamped
        end
        store!(directory, partition, partition, kept)
    end
    files = filter(path -> length(basename(path)) == 32 && all(isxdigit, basename(path)), readdir(directory; join = true))
    foreach(path -> rm(path; force = true), sort!(files; by = mtime, rev = true)[(LIBRARY_FILES + 1):end])
    return nothing
end

"""Entry file of checked `path` in cache `directory`."""
entry(directory::String, path::String)::String = joinpath(directory, bytes2hex(sha256(path))[1:32])

"""Whether cache `directory` holds no entry for checked `path`."""
cold(directory::String, path::String)::Bool = !isfile(entry(directory, path))

"""Analysis of type `T` stored for checked `path` under `key` in cache `directory`; `nothing` when entry is missing or has other key."""
function lookup(::Type{T}, directory::String, path::String, key::String)::Union{Nothing, T} where {T}
    file = entry(directory, path)
    isfile(file) || return nothing
    # Key line comes first, so entry from other Julia or Corset version is never deserialized.
    return open(io -> readline(io) == key ? deserialize(io)::T : nothing, file)
end

"""Store `analysis` under `key` as entry of checked `path` in cache `directory`. Entry file changes in one step."""
function store!(directory::String, path::String, key::String, analysis::T)::Nothing where {T}
    mkpath(directory)
    staging, io = mktemp(directory)
    println(io, key)
    serialize(io, analysis)
    close(io)
    mv(staging, entry(directory, path); force = true)
    return nothing
end

end
