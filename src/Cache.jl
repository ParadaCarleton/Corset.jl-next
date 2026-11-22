"""
Disk cache of analyses in one SQLite database: one entry per checked path, holding key and stored analysis. Key hashes
every analysis input, so changed input misses and run analyzes again. Library summaries of `effects` stage go by
partition (`partition_key`), whose entries every checked path and environment shares.
"""
module Cache

using DBInterface: DBInterface
using SQLite: SQLite
using Serialization: serialize, deserialize
using SHA: SHA, sha256
using Scratch: get_scratch!, delete_scratch!
using TOML: TOML
using URIs: escapepath
using Pkg.Artifacts: ensure_artifact_installed
using ..Launch: corset_root

"""Cache directory of command line: scratch space of Corset in Julia depot. CI that saves depot keeps it."""
function directory()::String
    corset = Base.moduleroot(@__MODULE__)
    # Scratch `analyses` held entry files before SQLite database; remove them.
    delete_scratch!(corset, "analyses")
    return get_scratch!(corset, "cache")
end

"""
Files under `root`, sorted. Names that start with dot stay out, with everything below them; so does directory `skipped`:
cache directory, whose entries would change key they are stored under, or code key leaves out.
"""
function tree_files(root::String, skipped::String)::Vector{String}
    files = String[]
    for (directory, directories, names) in walkdir(root)
        filter!(name -> !startswith(name, '.') && joinpath(directory, name) != skipped, directories)
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

"""`listed` files and every file of `trees`, directory `skipped` left out (`tree_files`), by real path and sorted."""
function found_files(listed::Vector{String}, trees::Vector{String}, skipped::String)::Vector{String}
    # Stale `path` entry names directory that is gone; it adds no file.
    found = [listed; (tree_files(tree, skipped) for tree in unique(trees) if isdir(tree))...]
    # Processes that reach file through other links must agree, so files count by real path.
    return sort!(unique!([ispath(file) ? realpath(file) : file for file in found]))
end

"""
Key line of method store of checked `path`: Julia version, cache flags, `path`, `engine` content (`engine_content`),
environment (`environment_inputs`), analyzed `files` by path, package `shape`, and files of project `root` that package
code loads from (`src`, `ext`, `deps`) but `files` leave out. Store entries count analyzed files by content, so Manifest
`path` entry of `root` stays out. `engine` counts apart: Corset that checks itself analyzes its own engine files.
"""
function method_key(path::String, root::String, files::Vector{String}, shape::Vector{String}, load_path::Vector{String}, engine::String, cache::String)::String
    parts, listed, trees = environment_inputs(load_path)
    root = realpath(root)
    analyzed = Set(ispath(file) ? realpath(file) : file for file in files)
    outside = filter(file -> !(file in analyzed), found_files(listed, store_trees(trees, root, reaches_corset(load_path, root)), cache))
    return digest([string(VERSION), repr(Base.CacheFlags()), path, engine, parts..., files..., shape...], outside)
end

"""
Trees of method store key: environment `trees` without analyzed project `root`, then package code directories of
`root`. Corset tree stays out unless package code `reaches` it: `engine` counts it then, without rule sources.
"""
function store_trees(trees::Vector{String}, root::String, reaches::Bool)::Vector{String}
    corset = realpath(corset_root())
    own = reaches ? (root,) : (root, corset, joinpath(corset, "src"))
    return [filter(tree -> !(ispath(tree) && realpath(tree) in own), trees); joinpath.(root, ["src", "ext", "deps"])]
end

"""
Whether package at `root` can depend on Corset, directly or through other packages, in environments of `load_path`.
Package starts from environment project at `root` or Manifest `path` entry of `root`; same-named entries all count.
Weak dependencies count: extension they trigger is package code too. Unknown reach counts as reach: `root` absent from
`load_path`, or dependency without Manifest entry.
"""
function reaches_corset(load_path::Vector{String}, root::String)::Bool
    corset, located = string(Base.PkgId(Base.moduleroot(@__MODULE__)).uuid), false
    for environment in filter(isfile, load_path)
        manifest = Base.project_file_manifest_path(environment)
        deps = isnothing(manifest) ? Dict{String, Any}() : Base.get_deps(TOML.parsefile(manifest))
        at_root(entry::Dict{String, Any})::Bool = haskey(entry, "path") && (path = abspath(dirname(manifest), entry["path"]); ispath(path) && realpath(path) == root)
        todo = String[name for (name, entries) in deps if any(at_root, entries)]
        own = realpath(dirname(environment)) == root
        own && append!(todo, dependency_names(TOML.parsefile(environment)))
        (own || !isempty(todo)) || continue
        located, seen = true, Set{String}()
        while !isempty(todo)
            name = pop!(todo)
            name in seen && continue
            push!(seen, name)
            haskey(deps, name) || return true
            for entry in deps[name]
                !at_root(entry) && get(entry, "uuid", "") == corset && return true
                append!(todo, dependency_names(entry))
            end
        end
    end
    return !located
end

"""
Names in `deps` and `weakdeps` of project or Manifest entry: weak dependency can trigger extension that calls it. Field
holds list of names, or table from name to uuid.
"""
function dependency_names(entry::Dict{String, Any})::Vector{String}
    names = String[]
    for field in ("deps", "weakdeps")
        listed = get(entry, field, String[])
        append!(names, listed isa Dict ? keys(listed) : listed)
    end
    return names
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
Content text of package `id` at `root`: name, UUID, portable store path or relative code digest, and preferences.
"""
function package_content(id::Base.PkgId, root::String, depots::Vector{String}, skipped::String)::String
    stores = [Sys.STDLIB; [joinpath(depot, "packages") for depot in depots]]
    store = findfirst(store -> startswith(root, joinpath(store, "")), stores)
    content = isnothing(store) ? package_digest(root, skipped) : relpath(root, stores[store])
    preferences = Base.get_preferences(id.uuid)
    return "$(id.name) $(id.uuid) $content" * (isempty(preferences) ? "" : "\n" * sprint(io -> TOML.print(io, preferences; sorted = true)))
end

"""Digest package code under `root` with portable relative file names, excluding `skipped`."""
function package_digest(root::String, skipped::String)::String
    root = realpath(root)
    files = found_files([joinpath(root, "Project.toml")], joinpath.(root, ["src", "ext", "deps"]), skipped)
    parts = String[]
    for file in files
        push!(parts, relpath(file, root), isfile(file) ? bytes2hex(sha256(read(file))) : "absent")
    end
    return digest(parts, String[])
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
    found = extension || root === Base.moduleroot(@__MODULE__) ? String[] : [package_content(id, something(directory), depots, "")]
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


"""Rule sources of Corset at `root`: stage facts never read them, so partition and method store keys leave them out."""
rule_sources(root::String)::String = joinpath(root, "src", "rules")

"""
Partition key of library summaries: Julia version `julia`, cache flags and content of Corset (`package_content`) under
`depots`, rule sources left out. Entry keys hold all else.
"""
partition_key(julia::String, depots::Vector{String})::String = digest([julia, repr(Base.CacheFlags()), engine_content(corset_root(), depots)], String[])

"""Content of Corset at `root` under `depots` (`package_content`), rule sources left out: stage facts depend on rest."""
function engine_content(root::String, depots::Vector{String})::String
    id = Base.PkgId(Base.moduleroot(@__MODULE__))
    return "$(id.name) $(id.uuid) $(package_digest(root, rule_sources(root)))"
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

"""Partitions that database keeps, newest first: summaries of other Julia or Corset versions drop out."""
const LIBRARY_PARTITIONS = 4

"""Entry bytes that partition keeps at most (`keep_library!`)."""
const LIBRARY_BYTES = 128 * 2^20

"""Layout version of database tables; database of other version starts empty."""
const LAYOUT = 1

"""Tables of cache database: analysis entry by checked path, library entries by partition, and partition use times."""
const TABLES = [
    "CREATE TABLE IF NOT EXISTS analyses (path TEXT PRIMARY KEY, key TEXT NOT NULL, bytes BLOB NOT NULL)",
    "CREATE TABLE IF NOT EXISTS library (partition TEXT NOT NULL, key TEXT NOT NULL, instance TEXT NOT NULL, bytes BLOB NOT NULL, used REAL NOT NULL, PRIMARY KEY (partition, key))",
    "CREATE INDEX IF NOT EXISTS library_instance ON library (partition, instance)",
    "CREATE TABLE IF NOT EXISTS partitions (partition TEXT PRIMARY KEY, used REAL NOT NULL)",
]

"""Database file of cache `directory`."""
database_file(directory::String)::String = joinpath(directory, "cache.sqlite")

"""Whether cache `directory` holds no database yet."""
missing_database(directory::String)::Bool = !isfile(database_file(directory))

"""
Value `body` gives with cache database of `directory` open, tables made; closes database on return or throw. Processes
share database: write waits for lock of other writer, and read sees last committed state.
"""
function with_database(body::Function, directory::String)::Any
    mkpath(directory)
    db = SQLite.DB(database_file(directory))
    try
        # Pragmas answer with row; `first_value` resets statement after it.
        first_value(db, "PRAGMA busy_timeout = 600000", ())
        first_value(db, "PRAGMA journal_mode = WAL", ())
        current() = something(first_value(db, "PRAGMA user_version", ()), 0) == LAYOUT
        # Other process can make tables meanwhile, so check again under write lock.
        if !current()
            immediate(db) do
                current() && return nothing
                foreach(table -> DBInterface.execute(db, "DROP TABLE IF EXISTS $table"), ("analyses", "library", "partitions"))
                foreach(statement -> DBInterface.execute(db, statement), TABLES)
                DBInterface.execute(db, "PRAGMA user_version = $LAYOUT")
            end
        end
        return body(db)
    finally
        close(db)
    end
end

"""
Value `body` gives inside write transaction of `db`; rolls back on throw. `BEGIN IMMEDIATE` takes write lock first:
reader that upgrades to writer fails at once when other writer holds lock, and busy timeout cannot help.
"""
function immediate(body::Function, db::SQLite.DB)::Any
    DBInterface.execute(db, "BEGIN IMMEDIATE")
    try
        result = body()
        DBInterface.execute(db, "COMMIT")
        return result
    catch
        DBInterface.execute(db, "ROLLBACK")
        rethrow()
    end
end

"""First column of first row that `sql` with `parameters` gives in `db`; `nothing` without row."""
function first_value(db::SQLite.DB, sql::String, parameters::Tuple)::Any
    query = DBInterface.execute(db, sql, parameters)
    try
        for row in query
            return row[1]
        end
        return nothing
    finally
        DBInterface.close!(query)
    end
end

"""Key of analysis entry of checked `path` in cache `directory`; `nothing` without entry."""
stored_key(directory::String, path::String)::Union{Nothing, String} =
    missing_database(directory) ? nothing : with_database(db -> first_value(db, "SELECT key FROM analyses WHERE path = ?", (path,)), directory)

"""Whether cache `directory` holds no entry for checked `path`."""
cold(directory::String, path::String)::Bool = isnothing(stored_key(directory, path))

"""Analysis of type `T` stored for checked `path` under `key` in cache `directory`; `nothing` when entry is missing or has other key."""
function lookup(::Type{T}, directory::String, path::String, key::String)::Union{Nothing, T} where {T}
    missing_database(directory) && return nothing
    # Query matches key first, so entry from other Julia or Corset version is never deserialized.
    bytes = with_database(db -> first_value(db, "SELECT bytes FROM analyses WHERE path = ? AND key = ?", (path, key)), directory)
    return isnothing(bytes) ? nothing : deserialize(IOBuffer(bytes))::T
end

"""Store `analysis` under `key` as entry of checked `path` in cache `directory`, in one transaction."""
function store!(directory::String, path::String, key::String, analysis::T)::Nothing where {T}
    buffer = IOBuffer()
    serialize(buffer, analysis)
    bytes = take!(buffer)
    with_database(db -> DBInterface.execute(db, "INSERT OR REPLACE INTO analyses (path, key, bytes) VALUES (?, ?, ?)", (path, key, bytes)), directory)
    return nothing
end

"""Library summaries of `partition` in open cache database `db`, read one entry at a time; `empty` when it holds none."""
struct Shelf
    db::SQLite.DB
    partition::String
    empty::Bool
    shipped::Union{Nothing, SQLite.DB}
end

"""Shelf of `partition` in open cache database `db`, with optional read-only `shipped` database."""
function Shelf(db::SQLite.DB, partition::String, shipped::Union{Nothing, SQLite.DB})::Shelf
    empty = isnothing(first_value(db, "SELECT 1 FROM library WHERE partition = ? LIMIT 1", (partition,)))
    if !isnothing(shipped)
        matching = !isnothing(first_value(shipped, "SELECT 1 FROM library WHERE partition = ? LIMIT 1", (partition,)))
        matching || println(stderr, "Corset: shipped library summaries have a different partition")
        empty &= !matching
        matching || (shipped = nothing)
    end
    return Shelf(db, partition, empty, shipped)
end

"""Use the declared summary artifact during `body`, unless an artifact build disables shipped reads."""
function with_shipped(body::Function)::Any
    get(ENV, "CORSET_BUILD_SUMMARIES", "") == "1" && return body(nothing)
    manifest = joinpath(corset_root(), "Artifacts.toml")
    (!isfile(manifest) || !haskey(TOML.parsefile(manifest), "library_summaries")) && return body(nothing)
    artifact = ensure_artifact_installed("library_summaries", manifest)
    path = joinpath(artifact, "library.sqlite")
    isfile(path) || error("Shipped library summary database is missing: $path")
    escaped = escapepath(abspath(path))
    shipped = SQLite.DB("file:$escaped?mode=ro&immutable=1")
    try
        first_value(shipped, "PRAGMA user_version", ()) == LAYOUT || error("Shipped library summary database has an incompatible layout")
        return body(shipped)
    finally
        close(shipped)
    end
end

"""Entry of `shelf` under `key`; `nothing` without one."""
function shelf_entry(shelf::Shelf, key::String)::Union{Nothing, Stamped}
    local_entry = shelf_entry(shelf.db, shelf.partition, key)
    return isnothing(local_entry) && !isnothing(shelf.shipped) ? shelf_entry(shelf.shipped, shelf.partition, key) : local_entry
end

"""Entry under `key` and `partition` in `db`; `nothing` when absent."""
function shelf_entry(db::SQLite.DB, partition::String, key::String)::Union{Nothing, Stamped}
    query = DBInterface.execute(db, "SELECT instance, bytes, used FROM library WHERE partition = ? AND key = ?", (partition, key))
    try
        for row in query
            return Stamped(row[1], row[2], row[3])
        end
        return nothing
    finally
        DBInterface.close!(query)
    end
end

"""Whether `shelf` holds entry under `key`."""
shelf_holds(shelf::Shelf, key::String)::Bool = any(db -> !isnothing(first_value(db, "SELECT 1 FROM library WHERE partition = ? AND key = ?", (shelf.partition, key))), filter(!isnothing, (shelf.db, shelf.shipped)))

"""Whether `shelf` holds entry of instance key `instance`."""
shelf_lists(shelf::Shelf, instance::String)::Bool = any(db -> !isnothing(first_value(db, "SELECT 1 FROM library WHERE partition = ? AND instance = ? LIMIT 1", (shelf.partition, instance))), filter(!isnothing, (shelf.db, shelf.shipped)))

"""
Merge `found` entries into `partition` of open cache database `db`, in one transaction. Found entries and `hits` take
time now; then entries go newest first while their bytes stay within `limit`. Database keeps newest
`LIBRARY_PARTITIONS` partitions. Concurrent writers wait for each other, so no entry is lost.
"""
function keep_library!(db::SQLite.DB, partition::String, found::Dict{String, Stamped}, hits::Set{String}, limit::Int)::Nothing
    now = time()
    immediate(db) do
        for (key, stamped) in found
            DBInterface.execute(db, "INSERT OR REPLACE INTO library (partition, key, instance, bytes, used) VALUES (?, ?, ?, ?, ?)", (partition, key, stamped.instance, stamped.bytes, now))
        end
        foreach(key -> DBInterface.execute(db, "UPDATE library SET used = ? WHERE partition = ? AND key = ?", (now, partition, key)), hits)
        DBInterface.execute(db, "INSERT OR REPLACE INTO partitions (partition, used) VALUES (?, ?)", (partition, now))
        # Key breaks ties of time, so processes agree on kept entries.
        DBInterface.execute(
            db, """DELETE FROM library WHERE partition = ?1 AND key IN (SELECT key FROM (SELECT key, SUM(length(bytes)) OVER
            (ORDER BY used DESC, key ROWS UNBOUNDED PRECEDING) AS total FROM library WHERE partition = ?1) WHERE total > ?2)""", (partition, limit)
        )
        old = "SELECT partition FROM partitions ORDER BY used DESC, partition LIMIT -1 OFFSET $LIBRARY_PARTITIONS"
        DBInterface.execute(db, "DELETE FROM library WHERE partition IN ($old)")
        DBInterface.execute(db, "DELETE FROM partitions WHERE partition IN ($old)")
    end
    return nothing
end

end
