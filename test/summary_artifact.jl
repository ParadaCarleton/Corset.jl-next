using Corset: Corset
using Pkg: Pkg
using TOML: TOML
using Test: @test, @testset, @test_throws

include(joinpath(@__DIR__, "..", "gen", "summaries", "build.jl"))

@testset "summary artifact round trip" begin
    mktempdir(@__DIR__) do scratch
        fixture = joinpath(scratch, "SummaryFixture")
        mkpath(joinpath(fixture, "src"))
        project = "name = \"SummaryFixture\"\nuuid = \"ac050f5a-7a06-4f96-9db6-dcc4744c69e7\"\n"
        write(joinpath(fixture, "Project.toml"), project)
        write(joinpath(fixture, "src", "SummaryFixture.jl"), "module SummaryFixture\n__init__() = println(\"fixture initialization output\")\nappend_one(xs::Vector{Int}) = (push!(xs, 1); length(xs))\nend\n")
        cache, manifest, output = joinpath.(scratch, ["cache", "Artifacts.toml", "output"])
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
            tarball = SummaryArtifact.build([fixture], cache, manifest, output, "https://example.org/releases", false)
            @test isfile(tarball)
        finally
            pop!(LOAD_PATH)
        end
        meta = Pkg.Artifacts.artifact_meta("library_summaries", manifest)
        @test length(TOML.parsefile(manifest)["library_summaries"]) == 1
        other_arch = Base.BinaryPlatforms.arch(Base.BinaryPlatforms.HostPlatform()) == "aarch64" ? "x86_64" : "aarch64"
        other_platform = Base.BinaryPlatforms.Platform(other_arch, "linux"; libc = "glibc")
        other_hash = Base.SHA1(hex2bytes("1111111111111111111111111111111111111111"))
        Pkg.Artifacts.bind_artifact!(manifest, "library_summaries", other_hash; platform = other_platform, lazy = true)
        SummaryArtifact.bind_platform(manifest, Base.SHA1(hex2bytes(meta["git-tree-sha1"])), only(meta["download"])["url"], only(meta["download"])["sha256"])
        @test Pkg.Artifacts.artifact_meta("library_summaries", manifest; platform = other_platform)["git-tree-sha1"] == bytes2hex(other_hash.bytes)
        download = only(meta["download"])
        @test download["url"] == "https://example.org/releases/library-summaries-$(download["sha256"]).tar.gz"
        @test meta["lazy"] && length(meta["git-tree-sha1"]) == 40
        @test read(joinpath(fixture, "Project.toml"), String) == project
        artifact = Pkg.Artifacts.ensure_artifact_installed("library_summaries", manifest)
        shipped_file = joinpath(artifact, "library.sqlite")
        before = read(shipped_file)
        partition = Corset.Cache.partition_key(string(VERSION), DEPOT_PATH)
        Corset.Cache.with_shipped(manifest, Base.BinaryPlatforms.HostPlatform()) do shipped
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
        end
        @test read(shipped_file) == before
        report_file = joinpath(scratch, "report.json")
        child = "using Corset: Corset; push!(LOAD_PATH, $(repr(fixture))); code = Corset.CLI.execute([\"check\", $(repr(fixture)), \"--kind\", \"library\", \"--format\", \"json\", \"--output\", $(repr(report_file))], stdout, stderr; launch=false, cache=nothing); exit(code in (0, 1) ? 0 : code)"
        output_text = read(`$(Base.julia_cmd()) --startup-file=no --project=test -e $child`, String)
        @test occursin("fixture initialization output", output_text)
        @test Corset.CLI.JSON.parsefile(report_file)["coverage"]["files"] > 0
    end
end

@testset "summary workload rejects failed checks" begin
    report = Dict("diagnostics" => [Dict("rule" => "ordinary")], "coverage" => Dict("files" => 1, "blind_spots" => []))
    @test isnothing(SummaryArtifact.complete_report("package", 1, report))
    report["diagnostics"] = [Dict("rule" => "load-error")]
    @test_throws ErrorException SummaryArtifact.complete_report("package", 1, report)
    report["diagnostics"] = [Dict("rule" => "parse-error")]
    @test_throws ErrorException SummaryArtifact.complete_report("package", 1, report)
    report["diagnostics"] = []
    # Blind spot leaves summary out; user run computes it.
    report["coverage"]["blind_spots"] = [Dict("cause" => "inference crashed process")]
    @test isnothing(SummaryArtifact.complete_report("package", 0, report))
    report["coverage"]["files"] = 0
    @test_throws ErrorException SummaryArtifact.complete_report("package", 0, report)
    @test_throws ErrorException SummaryArtifact.complete_report("package", 2, report)
    mktempdir(@__DIR__) do scratch
        fixture = joinpath(scratch, "BrokenFixture")
        mkpath(joinpath(fixture, "src"))
        write(joinpath(fixture, "Project.toml"), "name = \"BrokenFixture\"\nuuid = \"1b739cd4-84aa-4cd7-8b70-9ac84f15d54d\"\n")
        write(joinpath(fixture, "src", "BrokenFixture.jl"), "module BrokenFixture\nerror(\"load fails\")\nend\n")
        push!(LOAD_PATH, fixture)
        try
            @test_throws "load or parse errors" SummaryArtifact.check_workload([fixture], joinpath(scratch, "cache"), false)
        finally
            pop!(LOAD_PATH)
        end
    end
end
