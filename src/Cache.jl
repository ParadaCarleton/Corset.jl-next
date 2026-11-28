"""
Disk cache of analyses: one entry per analysis key, which hashes every analysis input, so changed input misses and run
analyzes again. Key names files relative to project root and environments (`anchors`), and entry stores paths below
root relative to it (`Relocating`): copy of project in other directory hits. Method store keeps one entry per checked
path. Library summaries of `effects` stage share one library file per partition (`partition_key`), whose entries every
checked path and environment shares.
"""
module Cache

using Serialization: Serialization, AbstractSerializer, serialize, deserialize
using SHA: SHA, sha256
using Scratch: get_scratch!
using TOML: TOML
"""Root directory of Corset package this process runs."""
corset_root()::String = pkgdir(Base.moduleroot(@__MODULE__))

"""
Entry files below `src` of Corset modules that make method store entries and library summaries: `Inference`, `Effects`,
each module they import, transitively, and `Cache`. Store and library keys hash these and files they include.
"""
const PRODUCERS = ("Cache.jl", "Config.jl", "Discovery.jl", "Effects/Effects.jl", "Facts.jl", "Guesses.jl", "HardArrays.jl", "Inference.jl", "Narrowing.jl", "Package.jl", "Signatures.jl", "StandIns.jl", "Syntax.jl", "Timings.jl", "Widening.jl")

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
Computed `include` calls that producers may make, by file below `src`: each loads checked package file, never Corset
code. Every other computed include in producer throws, as key could not follow it.
"""
const CHECKED_LOADS = ("Package.jl" => :(Base.include(container, entry)),)

"""Literal paths of `include` calls in parsed `expression` of `name` (path below `src`), outside quoted code."""
function included_paths(expression::Any, name::String)::Vector{String}
    expression isa Expr || return String[]
    expression.head in (:quote, :inert) && return String[]
    expression.head === :call && expression.args[1] in (:include, :(Base.include)) || return mapreduce(argument -> included_paths(argument, name), vcat, expression.args; init = String[])
    expression.args[end] isa String && return [expression.args[end]]
    (name => expression) in CHECKED_LOADS || throw(ArgumentError("$name: include of computed path, which producer key cannot follow; list checked package load in `CHECKED_LOADS`"))
    return String[]
end

"""Files of `source` that `entries` load: each entry and every file it includes, transitively, sorted. Missing file throws."""
function producer_files(source::String, entries::Tuple{Vararg{String}})::Vector{String}
    pending, found = normpath.(joinpath.(source, collect(entries))), Set{String}()
    while !isempty(pending)
        file = pop!(pending)
        file in found && continue
        push!(found, file)
        append!(pending, normpath.(joinpath.(dirname(file), included_paths(Meta.parseall(read(file, String); filename = file), relpath(file, source)))))
    end
    return sort!(collect(found))
end

"""Digest of each `producer_files` file of `source` and `entries` by path below `source` and content."""
function producer_digest(source::String, entries::Tuple{Vararg{String}})::String
    context = SHA.SHA256_CTX()
    for file in producer_files(source, entries)
        update_part!(context, relpath(file, source))
        update_part!(context, read(file, String))
    end
    return bytes2hex(SHA.digest!(context))
end

"""Digest of Corset producer source (`PRODUCERS`); location of Corset stays out."""
producer_digest()::String = producer_digest(joinpath(corset_root(), "src"), PRODUCERS)

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

"""`path` by real path when it exists."""
real_path(path::String)::String = ispath(path) ? realpath(path) : path

"""
How key names files: `anchors` map real directory to label (`anchored`). Each of `manifests`, Manifest of load path
environment, counts by entries with `path` entries anchored; other files count by bytes.
"""
struct Naming
    anchors::Vector{Pair{String, String}}
    manifests::Set{String}
end

"""Whether `file` holds text `path`."""
names_path(file::String, path::String)::Bool = isfile(file) && !isnothing(findfirst(codeunits(path), read(file)))

"""
`Naming` of key: real project `root` as `@root`, then each file of each project environment of `load_path`
(`environment_files`) as `@environment`, its position and file name. Root anchors only when no file of `files` but
Manifest names it: code that names own root can act on it, so its copy needs own key; root then labels itself. Entry
relocates root alone, so other files near environment keep real path.
"""
function naming(root::Union{Nothing, String}, load_path::AbstractVector{String}, files::AbstractVector{String})::Naming
    environments = filter(isfile, load_path)
    manifests = Set{String}(real_path(manifest) for manifest in Base.project_file_manifest_path.(environments) if !isnothing(manifest))
    real = isnothing(root) ? nothing : realpath(root)
    named = !isnothing(real) && any(file -> !(file in manifests) && names_path(file, real), files)
    anchors = isnothing(real) ? Pair{String, String}[] : [real => (named ? real : "@root")]
    for (position, environment) in enumerate(load_path), file in (environment in environments ? environment_files(environment) : String[])
        push!(anchors, real_path(file) => "@environment$position/" * basename(file))
    end
    return Naming(anchors, manifests)
end

"""Real project root whose copy shares key of `naming`; `nothing` when root does not anchor."""
function relocated_root(naming::Naming)::Union{Nothing, String}
    position = findfirst(anchor -> last(anchor) == "@root", naming.anchors)
    return isnothing(position) ? nothing : first(naming.anchors[position])
end

"""Name of real `path` in key: relative to first of `anchors` that holds it, else `path` itself."""
function anchored(path::String, anchors::AbstractVector{Pair{String, String}})::String
    for (directory, label) in anchors
        path == directory && return label
        prefix = joinpath(directory, "")
        startswith(path, prefix) && return label * "/" * chopprefix(path, prefix)
    end
    return path
end

"""
Content digest of `file` for key; `"absent"` when missing. Manifest of `naming` counts by its entries, each `path` entry
real and `anchored`: environment that develops copy of project then hashes as one that develops original.
"""
function content_digest(file::String, naming::Naming)::String
    isfile(file) || return "absent"
    file in naming.manifests || return bytes2hex(sha256(read(file)))
    manifest = TOML.parsefile(file)
    for entries in values(Base.get_deps(manifest)), entry in entries
        haskey(entry, "path") && (entry["path"] = anchored(real_path(abspath(dirname(file), entry["path"])), naming.anchors))
    end
    return bytes2hex(sha256(sprint(io -> TOML.print(io, manifest; sorted = true))))
end

"""Add `text` to `context` with its length first, so neighboring parts cannot run together."""
function update_part!(context::SHA.SHA256_CTX, text::String)::Nothing
    SHA.update!(context, codeunits(string(sizeof(text), ':')))
    SHA.update!(context, codeunits(text))
    return nothing
end

"""
Text parts, files and `Naming` that key of analysis of real checked `path` with `flags` text hashes. Parts: Julia
version, cache flags, `path`, `flags` and each environment of `load_path`, paths `anchored`. Files: analyzed `files`,
Corset source, each project environment with its Manifest and preferences, and every file of project root `root` and of
Manifest `path` entries, `cache` directory left out.
"""
function inputs(path::String, flags::String, root::Union{Nothing, String}, files::AbstractVector{String}, load_path::AbstractVector{String}, cache::String)::Tuple{Vector{String}, Vector{String}, Naming}
    parts, listed, trees = environment_inputs(load_path, [joinpath(corset_root(), "src")])
    found = found_files([files; listed], [trees; something(root, String[])], cache)
    named = naming(root, load_path, found)
    labeled = [anchored(real_path(part), named.anchors) for part in parts]
    return [string(VERSION), repr(Base.CacheFlags()), anchored(path, named.anchors), flags, labeled...], found, named
end

"""Project file `environment`, its Manifest and its preference files."""
function environment_files(environment::String)::Vector{String}
    preferences = joinpath.(dirname(environment), ["LocalPreferences.toml", "JuliaLocalPreferences.toml"])
    return [environment; something(Base.project_file_manifest_path(environment), String[]); preferences]
end

"""
Environment parts of key: each environment of `load_path`. Files: Corset project file, and each project environment
with its Manifest and preferences. Trees: `source` (Corset code key reads as tree) and Manifest `path` entries but
Corset root, which can hold depot and outputs beside code that Corset loads.
"""
function environment_inputs(load_path::AbstractVector{String}, source::AbstractVector{String})::Tuple{Vector{String}, Vector{String}, Vector{String}}
    corset = corset_root()
    parts, listed, trees = String[], [joinpath(corset, "Project.toml")], copy(source)
    for environment in load_path
        push!(parts, environment)
        # Directory environment, such as standard library, counts by path.
        isfile(environment) || continue
        append!(listed, environment_files(environment))
        # Relaunch develops Corset by path; its project file and source cover its code.
        append!(trees, filter(entry -> !(ispath(entry) && realpath(entry) == realpath(corset)), path_entries(environment)))
    end
    return parts, listed, trees
end

"""`listed` files and every file of `trees`, `cache` directory left out, by real path and sorted."""
function found_files(listed::AbstractVector{String}, trees::AbstractVector{String}, cache::String)::Vector{String}
    # Stale `path` entry names directory that is gone; it adds no file.
    found = [listed; (tree_files(tree, cache) for tree in unique(trees) if isdir(tree))...]
    # Processes that reach file through other links must agree, so files count by real path.
    return sort!(unique!(real_path.(found)))
end

"""
Key line of method store of checked `path`: Julia version, cache flags, `path`, Corset code that makes entries
(`producer_digest`), environment (`environment_inputs`), analyzed `files` by path, package `shape`, and files of project `root` that package code loads from (`src`, `ext`,
`deps`) but `files` leave out. Store entries count analyzed files by content, so Manifest `path` entry of `root` stays out.
Environments count by load path position (`naming`): relaunch copies environment to new temporary directory each run.
"""
function method_key(path::String, root::String, files::AbstractVector{String}, shape::AbstractVector{String}, load_path::AbstractVector{String}, cache::String)::String
    parts, listed, trees = environment_inputs(load_path, String[])
    root = realpath(root)
    kept = [filter(tree -> !(ispath(tree) && realpath(tree) == root), trees); joinpath.(root, ["src", "ext", "deps"])]
    analyzed = Set(real_path(file) for file in files)
    outside = filter(file -> !(file in analyzed), found_files(listed, kept, cache))
    named = naming(nothing, load_path, String[])
    labeled = [anchored(real_path(part), named.anchors) for part in parts]
    # Digest counts producer files even when checked package is Corset: `outside` drops analyzed files.
    return digest([string(VERSION), repr(Base.CacheFlags()), path, producer_digest(), labeled..., files..., shape...], outside, named)
end

"""
SHA-256 of `parts`, then of name and content of each of `files` in order of name: name `anchored` to anchors of
`naming`, content `content_digest`. Missing file counts too: file that appears changes digest.
"""
function digest(parts::AbstractVector{String}, files::AbstractVector{String}, naming::Naming)::String
    context = SHA.SHA256_CTX()
    foreach(part -> update_part!(context, part), parts)
    # Order by name: copies at other paths sort their files apart from files that keep real path.
    for (name, file) in sort!([(anchored(file, naming.anchors), file) for file in files])
        update_part!(context, name)
        update_part!(context, content_digest(file, naming))
    end
    return bytes2hex(SHA.digest!(context))
end

"""`digest` of `parts`, and of `files` by real path and bytes."""
digest(parts::AbstractVector{String}, files::AbstractVector{String})::String = digest(parts, files, Naming(Pair{String, String}[], Set{String}()))

"""
Key of analysis, digest of `inputs`, and real project root that entry stores as `ROOT_MARK` (`relocated_root`;
`nothing`: entry keeps paths, key names root).
"""
function key(path::String, flags::String, root::Union{Nothing, String}, files::AbstractVector{String}, load_path::AbstractVector{String}, cache::String)::Tuple{String, Union{Nothing, String}}
    parts, found, named = inputs(path, flags, root, files, load_path, cache)
    return digest(parts, found, named), relocated_root(named)
end

"""
Content text of package `id` at `root` for library entry key: name, UUID, then `root` for package in standard library
or in `packages` directory of one of `depots`, whose slug Pkg derives from Manifest tree hash. Path or developed package
gives digest of its code files instead: project file, `src`, `ext` and `deps`. Preferences of package count too.
"""
function package_content(id::Base.PkgId, root::String, depots::AbstractVector{String})::String
    stores = [Sys.STDLIB; [joinpath(depot, "packages") for depot in depots]]
    fixed = any(store -> startswith(root, joinpath(store, "")), stores)
    content = fixed ? root : digest(String[], found_files([joinpath(root, "Project.toml")], joinpath.(root, ["src", "ext", "deps"]), ""))
    preferences = Base.get_preferences(id.uuid)
    return "$(id.name) $(id.uuid) $content" * (isempty(preferences) ? "" : "\n" * sprint(io -> TOML.print(io, preferences; sorted = true)))
end

"""
Content texts that inference of code in module `mod` depends on (`engine.md`, Solve and cache): none for Base and
Core, as Julia version covers them; else content of its package (`package_content`) and texts of each loaded package
it depends on. Corset gives texts of its dependencies only: partition key holds its producer source, home of stand-ins. Extension depends on its
parent and triggers. `nothing` for module without package root on disk, such as `Main`. `texts` caches answers by root
module.
"""
function owner_texts!(texts::IdDict{Module, <:Union{Nothing, AbstractVector{String}}}, mod::Module, depots::AbstractVector{String})::Union{Nothing, Vector{String}}
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
Partition key of library file: Julia version `julia`, cache flags and Corset code that makes summaries
(`producer_digest`). Entry keys hold all else. Corset preferences stay out: they hold checked project's config.
"""
partition_key(julia::String)::String = digest([julia, repr(Base.CacheFlags()), producer_digest()], String[])

"""
Library cache entry: instance key of instance it describes (`Effects.Summaries.instance_key!`), serialized value, and time of
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
read_library(directory::String, partition::String)::Dict{String, Stamped} = something(lookup(Dict{String, Stamped}, directory, partition, partition; root = nothing), Dict{String, Stamped}())

"""
Merge `found` entries into library file of `partition` in library `directory`, read again just before write. Found
entries and `hits` take time now. Then entries go newest first while their bytes stay within `limit`. Run without found
entries writes no entries: it marks file as used. Directory keeps newest `LIBRARY_FILES` files; staging files of other
processes stay. Concurrent writer can lose entries of other, but file changes in one step.
"""
function keep_library!(directory::String, partition::String, found::AbstractDict{String, Stamped}, hits::AbstractSet{String}, limit::Integer)::Nothing
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
        store!(directory, partition, partition, kept; root = nothing)
    end
    files = filter(path -> length(basename(path)) == 32 && all(isxdigit, basename(path)), readdir(directory; join = true))
    foreach(path -> rm(path; force = true), sort!(files; by = mtime, rev = true)[(LIBRARY_FILES + 1):end])
    return nothing
end

"""Entry file of `name` in cache `directory`: checked path or analysis key."""
entry(directory::String, name::String)::String = joinpath(directory, bytes2hex(sha256(name))[1:32])

"""Whether cache `directory` holds no entry of `name`."""
cold(directory::String, name::String)::Bool = !isfile(entry(directory, name))

"""Text that entry holds in place of project root."""
const ROOT_MARK = "\0corset root\0"

"""
Serializer that replaces matches of `from` with `to` in each string it writes or reads. Entry stores project root as
`ROOT_MARK`, and read in copy of project gives paths below copy. `SubString` fails: its offsets would go stale.
"""
mutable struct Relocating{I <: IO, P <: Union{Regex, String}} <: AbstractSerializer
    io::I
    counter::Int
    table::IdDict{Any, Any}
    pending_refs::Vector{Int}
    known_object_data::Dict{UInt64, Any}
    version::Int
    from::P
    to::String
end

"""`Relocating` serializer of `io` that replaces `from` with `to`."""
Relocating(io::IO, from::Union{Regex, String}, to::String)::Relocating =
    Relocating(io, 0, IdDict{Any, Any}(), Int[], Dict{UInt64, Any}(), Serialization.ser_version, from, to)

Serialization.serialize(serializer::Relocating, text::String)::Nothing =
    invoke(serialize, Tuple{AbstractSerializer, String}, serializer, replace(text, serializer.from => serializer.to))

Serialization.serialize(::Relocating, text::SubString{String})::Union{} = error("cache entry holds substring `$text`, whose offsets relocation would break")

Serialization.deserialize_string(serializer::Relocating, length::Int)::String =
    replace(invoke(Serialization.deserialize_string, Tuple{AbstractSerializer, Int}, serializer, length), serializer.from => serializer.to)

"""
Project `root` as whole path in text: at start or after space, quote or bracket, and before separator, space, quote,
bracket, colon or end. Sibling `root2` and path `/x/root` stay.
"""
function root_pattern(root::String)::Regex
    # Backslash before character other than ASCII letter or digit makes it literal in PCRE.
    literal = replace(root, r"[^A-Za-z0-9]" => s"\\\0")
    return Regex("(?<![^\\s\"'`(\\[{<])" * literal * "(?=\$|[/\\s\"'`)\\]}>:,;])")
end

"""
Value of type `T` stored as entry of `name` under `key` in cache `directory`, paths below project `root` restored from
`ROOT_MARK` (`nothing`: none). `nothing` when entry is missing or has other key; hit makes entry new (`prune!`).
"""
function lookup(::Type{T}, directory::String, name::String, key::String; root::Union{Nothing, String})::Union{Nothing, T} where {T}
    # Other process can prune entry at any time: missing file is miss, and hit touches open file, never path.
    handle = try
        Base.Filesystem.open(entry(directory, name), Base.Filesystem.JL_O_RDONLY)
    catch failure
        failure isa Base.IOError && failure.code == Base.UV_ENOENT && return nothing
        rethrow()
    end
    try
        io = IOBuffer(read(handle))
        # Key line comes first, so entry from other Julia or Corset version is never deserialized.
        readline(io) == key || return nothing
        found = (isnothing(root) ? deserialize(io) : deserialize(Relocating(io, ROOT_MARK, root)))::T
        touch(handle)
        return found
    finally
        close(handle)
    end
end

"""
Store `value` under `key` as entry of `name` in cache `directory`, paths below project `root` as `ROOT_MARK` (`nothing`:
none). Fails when root stays in bytes outside strings, such as in `Symbol`. Entry file changes in one step.
"""
function store!(directory::String, name::String, key::String, value::T; root::Union{Nothing, String})::Nothing where {T}
    buffer = IOBuffer()
    if isnothing(root)
        serialize(buffer, value)
    else
        relocating = Relocating(buffer, root_pattern(root), ROOT_MARK)
        Serialization.writeheader(relocating)
        serialize(relocating, value)
    end
    bytes = take!(buffer)
    isnothing(root) || isnothing(findfirst(codeunits(joinpath(root, "")), bytes)) || error("cache entry of `$name` holds project root `$root` outside strings")
    mkpath(directory)
    staging, io = mktemp(directory)
    println(io, key)
    write(io, bytes)
    close(io)
    mv(staging, entry(directory, name); force = true)
    return nothing
end

"""Entry bytes that cache directory keeps at most (`prune!`): analyses and method stores."""
const ENTRY_BYTES = 512 * 2^20

"""
Delete oldest entry files of cache `directory` past `limit` bytes; newest entry always stays. Staging files and library
directory stay. Lookup hit makes entry new, so entries in use stay.
"""
function prune!(directory::String, limit::Integer)::Nothing
    # One `stat` per entry; entry that other process prunes meanwhile stats as no file (zeros) and drops out.
    found = [(path, stat(path)) for path in readdir(directory; join = true) if length(basename(path)) == 32 && all(isxdigit, basename(path))]
    total = 0
    for (position, (file, status)) in enumerate(sort!(filter!(isfile ∘ last, found); by = pair -> last(pair).mtime, rev = true))
        total += status.size
        position > 1 && total > limit && rm(file; force = true)
    end
    return nothing
end

end
