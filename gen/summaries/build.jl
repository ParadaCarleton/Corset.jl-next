"""Build a Julia artifact from library summaries gathered by Corset checks."""
module SummaryArtifact

    using Corset: Corset
    using Pkg: Pkg
    using TOML: TOML

    const Cache = Corset.Cache
    const Artifacts = Pkg.Artifacts

    """
    Reject failed check `report` for `path`: bad exit code, load or parse error, or no analyzed file. Findings and blind
    spots pass: missing summary only slows first user run.
    """
    function complete_report(path::String, code::Int, report::AbstractDict)::Nothing
        code in (Corset.CLI.EXIT_PASS, Corset.CLI.EXIT_FAIL) || error("Check failed for $path with exit code $code")
        failures = filter(diagnostic -> diagnostic["rule"] in ("load-error", "parse-error"), report["diagnostics"])
        isempty(failures) || error("Check of $path has load or parse errors: $(repr(failures))")
        coverage = report["coverage"]
        coverage["files"] > 0 || error("Check of $path analyzed no files")
        return nothing
    end

    """Run checks of `paths` with shared `cache` and reject incomplete analyses."""
    function check_workload(paths::Vector{String}, cache::String, launch::Bool)::Nothing
        mkpath(cache)
        for path in paths
            mktempdir(cache) do directory
                report = joinpath(directory, "report.json")
                code = Corset.CLI.execute(["check", path, "--effects", "--kind", "library", "--format", "json", "--output", report], stdout, stderr; launch, cache)
                code in (Corset.CLI.EXIT_PASS, Corset.CLI.EXIT_FAIL) || error("Check failed for $path with exit code $code")
                complete_report(path, code, Corset.CLI.JSON.parsefile(report))
            end
            println("Checked $path")
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

    """Check `paths`, archive summaries in `output`, and bind their URL under `url_prefix` in `manifest`."""
    function build(paths::Vector{String}, cache::String, manifest::String, output::String, url_prefix::String, launch::Bool)::String
        isempty(paths) && error("Summary workload is empty")
        without_binding(joinpath(pkgdir(Corset), "Artifacts.toml")) do
            check_workload(paths, cache, launch)
        end
        partition = Cache.partition_key(string(VERSION), DEPOT_PATH)
        hash = Artifacts.create_artifact() do directory
            export_partition(cache, directory, partition)
        end
        mkpath(output)
        return mktempdir(output) do directory
            temporary = joinpath(directory, "summary.tar.gz")
            digest = Artifacts.archive_artifact(hash, temporary)
            name = "library-summaries-$digest.tar.gz"
            tarball = joinpath(output, name)
            mv(temporary, tarball)
            bind_platform(manifest, hash, "$url_prefix/$name", digest)
            return tarball
        end
    end

    """Bind artifact `hash` for this host, replacing any legacy platform-independent binding."""
    function bind_platform(manifest::String, hash::Base.SHA1, url::String, digest::String)::Nothing
        original = isfile(manifest) ? read(manifest) : nothing
        try
            if !isnothing(original) && get(TOML.parsefile(manifest), "library_summaries", nothing) isa Dict
                Artifacts.unbind_artifact!(manifest, "library_summaries")
            end
            Artifacts.bind_artifact!(manifest, "library_summaries", hash; platform = Base.BinaryPlatforms.HostPlatform(), download_info = [(url, digest)], lazy = true, force = true)
        catch
            isnothing(original) || write(manifest, original)
            rethrow()
        end
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
        length(args) == 2 || error("Usage: build.jl RELEASE_ASSET_URL_PREFIX OUTPUT_DIRECTORY")
        url, output = args
        root = dirname(dirname(@__DIR__))
        mktempdir(@__DIR__) do temporary
            paths = workload(joinpath(temporary, "environment"))
            Pkg.activate(root)
            println(build(paths, joinpath(temporary, "cache"), joinpath(root, "Artifacts.toml"), abspath(output), url, true))
        end
        return nothing
    end

end

if abspath(PROGRAM_FILE) == @__FILE__
    SummaryArtifact.main(ARGS)
end
