# Disk cache: key inputs, entry storage, cached analysis, and command line with cache. Uses helpers of cli.jl.

using Corset: Corset
using Corset.Cache: Cache
using Corset.Config: Flags
using Test: @test, @testset, @test_throws

"""Write `files` (path => text) under `root`."""
function write_files(root::String, files::Pair{String, String}...)::Nothing
    for (path, text) in files
        mkpath(dirname(joinpath(root, path)))
        write(joinpath(root, path), text)
    end
    return nothing
end

"""Exit code, standard output and standard error of `corset args...` with cache directory `cache`."""
function cached_corset(cache::String, args::String...)::Tuple{Int, String, String}
    out, err = IOBuffer(), IOBuffer()
    code = Corset.CLI.execute(String[args...], out, err; launch = false, cache)
    return code, String(take!(out)), String(take!(err))
end

@testset "cache" begin
    @testset "tree files" begin
        mktempdir(@__DIR__) do root
            write_files(root, "b.jl" => "", "a/c.jl" => "", ".hidden.jl" => "", ".git/config" => "", "a/.d/e.jl" => "")
            write_files(root, "a/c.jl.123.cov" => "", "a/c.jl.123.mem" => "", "cache/entry" => "", "cached/entry" => "")
            symlink(joinpath(root, "a"), joinpath(root, "directory link"))
            symlink(joinpath(root, "b.jl"), joinpath(root, "file link"))
            @test Cache.tree_files(root, joinpath(root, "cache")) == joinpath.(root, ["a/c.jl", "b.jl", "cached/entry", "file link"])
        end
    end

    @testset "key inputs" begin
        mktempdir(@__DIR__) do scratch
            root, dependency, environment = joinpath.(scratch, ["root", "dependency", "environment"])
            write_files(root, "Project.toml" => "", "src/a.jl" => "a = 1\n", ".hidden" => "")
            write_files(dependency, "src/D.jl" => "module D end\n")
            gone = "\n[[deps.Gone]]\npath = \"../gone\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\n"
            manifest = "manifest_format = \"2.0\"\n\n[[deps.D]]\npath = \"../dependency\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\n$gone"
            write_files(environment, "Project.toml" => "", "Manifest.toml" => manifest)
            script = joinpath(scratch, "script.jl")
            write(script, "x = 1\n")
            project = joinpath(environment, "Project.toml")
            parts, files = Cache.inputs(root, "flags", root, [joinpath(root, "src", "a.jl"), script], [project, Sys.STDLIB], joinpath(root, "cache"))
            @test parts == [string(VERSION), repr(Base.CacheFlags()), root, "flags", project, Sys.STDLIB]
            corset = realpath(pkgdir(Corset))
            listed = [
                joinpath(root, "Project.toml"), joinpath(root, "src", "a.jl"), script, joinpath(dependency, "src", "D.jl"),
                project, joinpath(environment, "Manifest.toml"), joinpath(environment, "LocalPreferences.toml"), joinpath(environment, "JuliaLocalPreferences.toml"),
                joinpath(corset, "Project.toml"), joinpath(corset, "src", "Cache.jl"),
            ]
            @test issubset(listed, files) && issorted(files) && allunique(files)
            @test !any(file -> occursin("hidden", file) || occursin("gone", file), files)
            # Manifest format 1 keeps entries at top level.
            write_files(environment, "Manifest.toml" => "[[D]]\npath = \"../dependency\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\n")
            @test Cache.path_entries(project) == [dependency]
            # Script outside project counts only its own files.
            @test !any(startswith(root), last(Cache.inputs(script, "flags", nothing, [script], String[], joinpath(scratch, "cache"))))
        end
    end

    @testset "digest" begin
        mktempdir(@__DIR__) do root
            file, missing_file = joinpath(root, "a.jl"), joinpath(root, "b.jl")
            write(file, "a = 1\n")
            digest() = Cache.digest(["part"], [file, missing_file])
            seen = [digest()]
            @test digest() == only(seen)
            for change in (() -> write(file, "a = 2\n"), () -> write(missing_file, ""))
                change()
                push!(seen, digest())
            end
            push!(seen, Cache.digest(["other part"], [file, missing_file]))
            # Length prefix keeps part boundaries: two parts never digest as one.
            push!(seen, Cache.digest(["ab", "c"], String[]), Cache.digest(["a", "bc"], String[]))
            @test allunique(seen)
        end
    end

    @testset "entries" begin
        mktempdir(@__DIR__) do directory
            cache = joinpath(directory, "cache")
            @test Cache.cold(cache, "/checked") && isnothing(Cache.lookup(String, cache, "/checked", "key"))
            Cache.store!(cache, "/checked", "key", "first")
            Cache.store!(cache, "/checked", "key", "stored")
            @test !Cache.cold(cache, "/checked") && Cache.cold(cache, "/other")
            @test Cache.lookup(String, cache, "/checked", "key") == "stored"
            @test isnothing(Cache.lookup(String, cache, "/checked", "other key"))
            # Entry is file per checked path; no staging file stays behind.
            @test readdir(cache) == [basename(Cache.entry(cache, "/checked"))]
            @test_throws TypeError Cache.lookup(Int, cache, "/checked", "key")
        end
    end

    @testset "cached analysis" begin
        mktempdir(@__DIR__) do scratch
            cache, directory = joinpath(scratch, "cache"), joinpath(scratch, "scripts")
            # Own Project.toml keeps test directory, which holds `cache`, out of key.
            write_files(directory, "Project.toml" => "[deps]\n", "a.jl" => "total = 1.0\ntotal ≈ 0\n")
            checked = realpath(directory)
            @test isnothing(Corset.Engine.cached(directory, Flags(), cache, Base.load_path()))
            @test length(Corset.check(directory; cache).diagnostics) == 1
            settings, stored = Corset.Engine.cached(directory, Flags(), cache, Base.load_path())
            @test settings.confidence == Corset.Facts.Confidence.definite && stored.files == [joinpath(checked, "a.jl")]
            @test isnothing(Corset.Engine.cached(directory, Flags(; deny_warnings = true), cache, Base.load_path()))
            # Stored analysis serves check: entry with no diagnostics hides finding.
            key = readline(Cache.entry(cache, checked))
            Cache.store!(cache, checked, key, Corset.Engine.Analysis(checked, stored.files, [], [], [], []))
            @test isempty(Corset.check(directory; cache).diagnostics)
            @test Corset.Engine.baseline(directory; cache) == 0
            write(joinpath(directory, "a.jl"), "total = 1.0\ntotal ≈ 0\n\n")
            @test length(Corset.check(directory; cache).diagnostics) == 1
            @test readline(Cache.entry(cache, checked)) != key
        end
    end

    @testset "command line" begin
        mktempdir(@__DIR__) do scratch
            cache, directory = joinpath(scratch, "cache"), joinpath(scratch, "scripts")
            write_files(directory, "Project.toml" => "[deps]\n", "a.jl" => "total = 1.0\ntotal ≈ 0\n")
            code, out, err = cached_corset(cache, "check", directory)
            @test code == 1 && occursin("approx-zero", out) && err == "corset: no cached analysis of $directory; first run can be slow, later runs reuse it\n"
            @test cached_corset(cache, "check", directory) == (code, out, "")
            @test cached_corset(cache, "check", directory, "--format", "json")[2] == corset("check", directory, "--format", "json")[2]
            # `--no-cache` reads and writes nothing.
            other = joinpath(scratch, "other")
            write_files(other, "Project.toml" => "[deps]\n", "a.jl" => "total = 1.0\ntotal ≈ 0\n")
            @test cached_corset(cache, "check", other, "--no-cache") == (code, out, "")
            @test Cache.cold(cache, realpath(other))
            # Fix through cache matches fix without it.
            fixed, plain = cached_corset(cache, "fix", directory), corset("fix", other)
            @test fixed[1:2] == plain[1:2] && read(joinpath(directory, "a.jl"), String) == read(joinpath(other, "a.jl"), String)
        end
        # Package run: blind spots and load problems come back from cache.
        computed = "\"\"\"Package with computed include.\"\"\"\nmodule Cached\ninclude(string(\"part\", \".jl\"))\nend\n"
        with_package(@__DIR__, "Cached", "src/Cached.jl" => computed, "src/part.jl" => "part_value = 1\n") do package
            mktempdir(@__DIR__) do cache
                first = cached_corset(cache, "check", package)
                @test occursin("skipped 1", first[2]) && cached_corset(cache, "check", package) == (first[1], first[2], "")
            end
        end
    end
end
