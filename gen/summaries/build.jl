"""Build a Julia artifact from library summaries gathered by Corset checks."""
module SummaryArtifact

    using Corset: Corset
    using Pkg: Pkg
    using TOML: TOML

    const Cache = Corset.Cache
    const Artifacts = Pkg.Artifacts

    """Run checks of `paths` with shared `cache` and reject internal errors."""
    function check_workload(paths::Vector{String}, cache::String, launch::Bool)::Nothing
        for path in paths
            code = Corset.CLI.execute(["check", path, "--effects"], stdout, stderr; launch, cache)
            code in (Corset.CLI.EXIT_PASS, Corset.CLI.EXIT_FAIL) || error("Check failed for $path with exit code $code")
        end
        return nothing
    end

    """Run `body` without the summary binding in `manifest`; restore its original bytes on exit."""
    function without_binding(body::Function, manifest::String)::Any
        (!isfile(manifest) || !haskey(TOML.parsefile(manifest), "library_summaries")) && return body()
        original = read(manifest)
        try
            Artifacts.unbind_artifact!(manifest, "library_summaries")
            return body()
        finally
            write(manifest, original)
        end
    end

    """Copy rows of `partition` from `cache` to a fresh SQLite database in `directory`."""
    function export_partition(cache::String, directory::String, partition::String)::Nothing
        Cache.with_database(cache) do source
            Cache.with_database(directory) do destination
                rows = Cache.DBInterface.execute(source, "SELECT key, instance, bytes, used FROM library WHERE partition = ?", (partition,))
                count = 0
                try
                    Cache.immediate(destination) do
                        for row in rows
                            Cache.DBInterface.execute(destination, "INSERT INTO library (partition, key, instance, bytes, used) VALUES (?, ?, ?, ?, ?)", (partition, row[1], row[2], row[3], row[4]))
                            count += 1
                        end
                    end
                finally
                    Cache.DBInterface.close!(rows)
                end
                count > 0 || error("No library summaries found for current partition")
            end
        end
        mv(Cache.database_file(directory), joinpath(directory, "library.sqlite"))
        return nothing
    end

    """Check `paths`, archive their summaries to `tarball`, and bind `url` in `manifest`."""
    function build(paths::Vector{String}, cache::String, manifest::String, tarball::String, url::String, launch::Bool)::Nothing
        isempty(paths) && error("Summary workload is empty")
        without_binding(joinpath(pkgdir(Corset), "Artifacts.toml")) do
            check_workload(paths, cache, launch)
        end
        partition = Cache.partition_key(string(VERSION), DEPOT_PATH)
        hash = Artifacts.create_artifact() do directory
            export_partition(cache, directory, partition)
        end
        digest = Artifacts.archive_artifact(hash, tarball)
        Artifacts.bind_artifact!(manifest, "library_summaries", hash; download_info = [(url, digest)], lazy = true, force = true)
        return nothing
    end

    """Install workload packages in `environment` and return their source paths."""
    function workload(environment::String)::Vector{String}
        names = TOML.parsefile(joinpath(@__DIR__, "workload.toml"))["packages"]::Vector
        Pkg.activate(environment)
        Pkg.develop(path = dirname(dirname(@__DIR__)))
        Pkg.add([Pkg.PackageSpec(name = name) for name in names])
        dependencies = Pkg.dependencies()
        paths = String[dirname(dirname(@__DIR__))]
        for name in names
            packages = filter(package -> package.name == name && !isnothing(package.source), collect(values(dependencies)))
            length(packages) == 1 || error("Cannot locate workload package $name")
            push!(paths, something(only(packages).source))
        end
        return paths
    end

    """Build release artifact from workload packages and command-line release asset URL."""
    function main(args::Vector{String})::Nothing
        length(args) == 2 || error("Usage: build.jl RELEASE_ASSET_URL TARBALL_PATH")
        url, tarball = args
        root = dirname(dirname(@__DIR__))
        mktempdir(@__DIR__) do temporary
            paths = workload(joinpath(temporary, "environment"))
            Pkg.activate(root)
            build(paths, joinpath(temporary, "cache"), joinpath(root, "Artifacts.toml"), abspath(tarball), url, true)
        end
        return nothing
    end

end

if abspath(PROGRAM_FILE) == @__FILE__
    SummaryArtifact.main(ARGS)
end
