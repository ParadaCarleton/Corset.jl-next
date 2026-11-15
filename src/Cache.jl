"""
Disk cache of analyses: one entry per checked path, holding key and stored analysis. Key hashes every analysis input,
so changed input misses and run analyzes again.
"""
module Cache

using Serialization: serialize, deserialize
using SHA: SHA, sha256
using Scratch: get_scratch!
using TOML: TOML
using ..Launch: corset_root

"""Cache directory of command line: scratch space of Corset in Julia depot. CI that saves depot keeps it."""
directory()::String = get_scratch!(Base.moduleroot(@__MODULE__), "analyses")

"""Coverage and allocation files Julia writes beside source while code runs; no analysis reads them."""
const RUN_OUTPUT = r"\.(cov|mem)$"

"""
Files under `root`, sorted. Names that start with dot stay out, with everything below them; so do `RUN_OUTPUT` files
and directory `cache`, whose entries would change key they are stored under.
"""
function tree_files(root::String, cache::String)::Vector{String}
    files = String[]
    for (directory, directories, names) in walkdir(root)
        filter!(name -> !startswith(name, '.') && joinpath(directory, name) != cache, directories)
        # Symbolic link to directory arrives in `names`; `isfile` drops it.
        kept = [joinpath(directory, name) for name in names if !startswith(name, '.') && !occursin(RUN_OUTPUT, name)]
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
    parts = [string(VERSION), repr(Base.CacheFlags()), path, flags]
    corset = corset_root()
    trees = [joinpath(corset, "src"); something(root, String[])]
    listed = [files; joinpath(corset, "Project.toml")]
    for environment in load_path
        push!(parts, environment)
        # Directory environment, such as standard library, counts by path.
        isfile(environment) || continue
        directory = dirname(environment)
        append!(listed, [environment; something(Base.project_file_manifest_path(environment), String[]); joinpath.(directory, ["LocalPreferences.toml", "JuliaLocalPreferences.toml"])])
        append!(trees, path_entries(environment))
    end
    # Stale `path` entry names directory that is gone; it adds no file.
    found = [listed; (tree_files(tree, cache) for tree in unique(trees) if isdir(tree))...]
    # Processes that reach file through other links must agree, so files count by real path.
    return parts, sort!(unique!([ispath(file) ? realpath(file) : file for file in found]))
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
