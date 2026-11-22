# Helpers that read cache database in tests; `helpers.jl` and `summary_cache.jl` include it.

using Corset: Corset

"""First column of each row that `sql` with `parameters` gives in database of cache `directory`."""
cache_column(directory::String, sql::String, parameters::Tuple)::Vector{Any} =
    Corset.Cache.with_database(db -> Any[row[1] for row in Corset.Cache.DBInterface.execute(db, sql, parameters)], directory)

"""Remove analysis entry of checked `path` from cache `directory`."""
forget!(directory::String, path::String)::Nothing = (cache_column(directory, "DELETE FROM analyses WHERE path = ?", (path,)); nothing)
