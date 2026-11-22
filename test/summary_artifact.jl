using Corset: Corset
using Pkg: Pkg
using TOML: TOML
using Test: @test, @testset, @test_throws

include(joinpath(@__DIR__, "..", "gen", "summaries", "build.jl"))

@testset "summary artifact round trip" begin
    mktempdir(@__DIR__) do scratch
        fixture = joinpath(scratch, "SummaryFixture")
        mkpath(joinpath(fixture, "src"))
        write(joinpath(fixture, "Project.toml"), "name = \"SummaryFixture\"\nuuid = \"ac050f5a-7a06-4f96-9db6-dcc4744c69e7\"\n[preferences.Corset]\nkind = \"library\"\n")
        write(joinpath(fixture, "src", "SummaryFixture.jl"), "module SummaryFixture\nappend_one(xs::Vector{Int}) = (push!(xs, 1); length(xs))\nend\n")
        cache, manifest, tarball = joinpath.(scratch, ["cache", "Artifacts.toml", "summaries.tar.gz"])
        original = "[library_summaries]\ngit-tree-sha1 = \"0000000000000000000000000000000000000000\"\n\n[other]\ngit-tree-sha1 = \"1111111111111111111111111111111111111111\"\n"
        write(manifest, original)
        SummaryArtifact.without_binding(manifest) do
            @test !haskey(TOML.parsefile(manifest), "library_summaries") && haskey(TOML.parsefile(manifest), "other")
        end
        @test read(manifest, String) == original
        @test_throws ErrorException SummaryArtifact.without_binding(() -> error("failure"), manifest)
        @test read(manifest, String) == original
        push!(LOAD_PATH, fixture)
        try
            SummaryArtifact.build([fixture], cache, manifest, tarball, "https://example.org/summaries.tar.gz", false)
        finally
            pop!(LOAD_PATH)
        end
        meta = TOML.parsefile(manifest)["library_summaries"]
        @test isfile(tarball) && meta["lazy"] && length(meta["git-tree-sha1"]) == 40
        artifact = Pkg.Artifacts.ensure_artifact_installed("library_summaries", manifest)
        shipped_file = joinpath(artifact, "library.sqlite")
        before = read(shipped_file)
        partition = Corset.Cache.partition_key(string(VERSION), DEPOT_PATH)
        shipped = Corset.Cache.SQLite.DB("file:" * Corset.Cache.escapepath(shipped_file) * "?mode=ro&immutable=1")
        try
            Corset.Cache.with_database(cache) do local_db
                rows = Corset.Cache.DBInterface.execute(local_db, "SELECT key FROM library WHERE partition = ? LIMIT 1", (partition,))
                key = try
                    first(rows)[1]
                finally
                    Corset.Cache.DBInterface.close!(rows)
                end
                Corset.Cache.with_database(joinpath(scratch, "empty")) do empty_db
                    shelf = Corset.Cache.Shelf(empty_db, partition, shipped)
                    @test Corset.Cache.shelf_holds(shelf, key)
                    @test !isnothing(Corset.Cache.shelf_entry(shelf, key))
                end
            end
        finally
            close(shipped)
        end
        @test read(shipped_file) == before
    end
end
