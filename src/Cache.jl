"""
Disk cache of analyses: one entry per checked path, holding key and stored analysis. Key hashes every analysis input,
so changed input misses and run analyzes again. Library summaries of `effects` stage keep one entry per environment of
loaded packages (`library_key`), which every checked path shares.
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
update_part!(context::SHA.SHA256_CTX, text::String)::Nothing = (SHA.update!(context, codeunits("$(sizeof(text)):$text")); nothing)

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
Content text of package `id` at `root` for library key: name, UUID and `root` for package in standard library or in
`packages` directory of one of `depots`, whose slug Pkg derives from Manifest tree hash. Path or developed package
gives digest of its code files instead: project file, `src`, `ext` and `deps`.
"""
function package_content(id::Base.PkgId, root::String, depots::Vector{String})::String
    stores = [Sys.STDLIB; [joinpath(depot, "packages") for depot in depots]]
    fixed = any(store -> startswith(root, joinpath(store, "")), stores)
    content = fixed ? root : digest(String[], found_files([joinpath(root, "Project.toml")], joinpath.(root, ["src", "ext", "deps"]), ""))
    return "$(id.name) $(id.uuid) $content"
end

"""
Key of library summaries (`effects.md`, Solve and cache): Julia version `julia`, cache flags, and content of each of
loaded `packages` (`package_content`) with their roots, under `depots`.
"""
function library_key(julia::String, packages::Vector{Pair{Base.PkgId, String}}, depots::Vector{String})::String
    return digest([julia; repr(Base.CacheFlags()); sort!([package_content(id, root, depots) for (id, root) in packages])], String[])
end

"""
Loaded packages outside target package `modules`, extensions included, each with its root directory. Library summary
reaches no target method, so target edit keeps key. Base and Core have no package root: Julia version covers them.
"""
function loaded_packages(modules::Vector{Module})::Vector{Pair{Base.PkgId, String}}
    target = Set(Base.PkgId(Base.moduleroot(mod)) for mod in modules)
    found = Pair{Base.PkgId, String}[]
    for mod in Base.loaded_modules_array()
        id, root = Base.PkgId(mod), pkgdir(mod)
        id in target || isnothing(root) || push!(found, id => root)
    end
    return found
end

"""Library summary directory of cache `directory`: one entry per library key."""
library_directory(directory::String)::String = joinpath(directory, "library")

"""Library entries that library directory keeps, newest first: entries of other environments drop out."""
const LIBRARY_ENTRIES = 4

"""
Keep library summaries of `key` in library `directory`: store `library`, or mark stored entry as used when `nothing`.
Then delete all but newest `LIBRARY_ENTRIES` entries; staging files of other processes stay.
"""
function keep_library!(directory::String, key::String, library::Any)::Nothing
    if isnothing(library)
        isfile(entry(directory, key)) || return nothing
        touch(entry(directory, key))
    else
        store!(directory, key, key, library)
    end
    entries = filter(file -> length(basename(file)) == 32 && all(isxdigit, basename(file)), readdir(directory; join = true))
    foreach(file -> rm(file; force = true), sort!(entries; by = mtime, rev = true)[(LIBRARY_ENTRIES + 1):end])
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
