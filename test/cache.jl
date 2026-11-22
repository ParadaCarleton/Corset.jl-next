# Disk cache: key inputs, entry storage, cached analysis, and command line with cache.

include("helpers.jl")

using Corset: Corset
using Corset.Cache: Cache
using Corset.Config: Flags
using Test: @test, @testset, @test_throws
using Random: RandomDevice

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
            write_files(root, "cache/entry" => "", "cached/entry" => "")
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
            script, link = joinpath(scratch, "script.jl"), joinpath(scratch, "link.jl")
            write(script, "x = 1\n")
            symlink(script, link)
            project = joinpath(environment, "Project.toml")
            parts, files = Cache.inputs(root, "flags", root, [joinpath(root, "src", "a.jl"), link], [project, Sys.STDLIB], joinpath(root, "cache"))
            @test parts == [string(VERSION), repr(Base.CacheFlags()), root, "flags", project, Sys.STDLIB]
            corset = realpath(pkgdir(Corset))
            listed = [
                joinpath(root, "Project.toml"), joinpath(root, "src", "a.jl"), script, joinpath(dependency, "src", "D.jl"),
                project, joinpath(environment, "Manifest.toml"), joinpath(environment, "LocalPreferences.toml"), joinpath(environment, "JuliaLocalPreferences.toml"),
                joinpath(corset, "Project.toml"), joinpath(corset, "src", "Cache.jl"),
            ]
            @test issubset(listed, files) && issorted(files) && allunique(files)
            @test !any(file -> occursin("hidden", file) || occursin("gone", file) || occursin("link", file), files)
            # Manifest format 1 keeps entries at top level.
            write_files(environment, "Manifest.toml" => "[[D]]\npath = \"../dependency\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\n")
            @test Cache.path_entries(project) == [dependency]
            # Script outside project counts only its own files.
            @test !any(startswith(root), last(Cache.inputs(script, "flags", nothing, [script], String[], joinpath(scratch, "cache"))))
        end
    end

    @testset "method store key" begin
        mktempdir(@__DIR__) do scratch
            root, environment = joinpath.(scratch, ["root", "environment"])
            write_files(root, "Project.toml" => "", "src/A.jl" => "a = 1\n", "src/b.jl" => "", "test/runtests.jl" => "")
            # Environment develops root by path; entries count analyzed files, so root tree stays out.
            manifest = "manifest_format = \"2.0\"\n\n[[deps.A]]\npath = \"../root\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\n"
            write_files(environment, "Project.toml" => "", "Manifest.toml" => manifest)
            analyzed = [joinpath(root, "src", "A.jl")]
            key(shape::Vector{String}, files::Vector{String})::String =
                Cache.method_key(root, root, files, shape, [joinpath(environment, "Project.toml")], joinpath(root, "cache"))
            original = key(["shape"], analyzed)
            write_files(root, "src/A.jl" => "a = 2\n", "test/runtests.jl" => "b = 1\n")
            @test key(["shape"], analyzed) == original
            # Stage reads which files hold package code, so analyzed file list counts.
            @test key(["other shape"], analyzed) != original && key(["shape"], [analyzed; joinpath(root, "test", "runtests.jl")]) != original
            # File of `src` that run does not analyze can change package code.
            write_files(root, "src/b.jl" => "b = 1\n")
            @test key(["shape"], analyzed) != original
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
        # Rerun after edit takes facts of unchanged files from method store.
        entry = "\"\"\"Package with two files.\"\"\"\nmodule Stored\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n"
        first_part, second_part = "first_part(x::Real) = x + 1\n", "second_part(x::Real) = x * 2\n"
        with_package(@__DIR__, "Stored", "src/Stored.jl" => entry, "src/a.jl" => first_part, "src/b.jl" => second_part) do package
            mktempdir(@__DIR__) do cache
                @test first(cached_corset(cache, "check", package)) == 0
                checked, store_entry = realpath(package), Corset.Engine.method_entry(realpath(package))
                key, b = readline(Cache.entry(cache, store_entry)), joinpath(realpath(package), "src", "b.jl")
                store = Cache.lookup(Corset.Inference.Store, cache, store_entry, key)
                # Entry of `second_part` that claims failing call shows store serves facts.
                held = first(name for (name, held) in store if first(held.file) == b)
                span = Corset.Facts.Span(b, 1, 11, Corset.Facts.Precision.exact)
                fake = Corset.Facts.FailingCall(span, span, "fake", Corset.Facts.Confidence.definite)
                bytes = Corset.Inference.serialized(Corset.Inference.Inferred(Union{}, Tuple{Type, Type}[], Type[], [1 => fake], true, false, Corset.Facts.Disruption[], Corset.Facts.HardArray[], Corset.Facts.NarrowingLoss[], Corset.Facts.StatefulIterate[]))
                store[held] = Corset.Inference.Entry(store[held].file, store[held].methods, store[held].staged, bytes, store[held].effects)
                Cache.store!(cache, store_entry, key, store)
                write(joinpath(checked, "src", "a.jl"), first_part * "\n")
                @test occursin("call to `fake` never succeeds", cached_corset(cache, "check", package)[2])
                write(b, second_part * "\n")
                @test first(cached_corset(cache, "check", package)) == 0
                rm(Cache.entry(cache, store_entry))
                write(b, second_part)
                @test first(cached_corset(cache, "check", package, "--no-cache")) == 0 && Cache.cold(cache, store_entry)
            end
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
