# Disk cache: key inputs, entry storage, cached analysis, and command line with cache.

include("helpers.jl")

using Corset: Corset
using Corset.Cache: Cache
using Corset.Config: Flags
using Test: @test, @testset, @test_throws
using Random: Random, RandomDevice

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
            key(shape::Vector{String}, files::Vector{String}, engine::String = "engine")::String =
                Cache.method_key(root, root, files, shape, [joinpath(environment, "Project.toml")], engine, joinpath(root, "cache"))
            original = key(["shape"], analyzed)
            write_files(root, "src/A.jl" => "a = 2\n", "test/runtests.jl" => "b = 1\n")
            @test key(["shape"], analyzed) == original
            # Stage reads which files hold package code, so analyzed file list counts.
            @test key(["other shape"], analyzed) != original && key(["shape"], [analyzed; joinpath(root, "test", "runtests.jl")]) != original
            # File of `src` that run does not analyze can change package code.
            write_files(root, "src/b.jl" => "b = 1\n")
            @test key(["shape"], analyzed) != original
            # Engine counts though analyzed files hold it: Corset that checks itself must not reuse facts of old engine.
            corset = [joinpath(Corset.Launch.corset_root(), "src", "Corset.jl")]
            @test key(["shape"], corset, "engine") != key(["shape"], corset, "edited engine")
            # Manifest `path` entry of Corset leaves its tree out, so rule edits keep stored facts; package that reaches Corset keeps it.
            home, other, real = Corset.Launch.corset_root(), joinpath(scratch, "environment"), realpath(root)
            code = joinpath.(real, ["src", "ext", "deps"])
            @test Cache.store_trees([home, joinpath(home, "src"), other, root], real, false) == [other; code]
            @test Cache.store_trees([home, other, root], real, true) == [home, other, code...]
        end
    end

    @testset "reaches Corset" begin
        mktempdir(@__DIR__) do scratch
            root, environment = joinpath.(scratch, ["root", "environment"])
            corset, uuid = Corset.Launch.corset_root(), Base.UUID(rand(UInt128))
            write_files(root, "Project.toml" => "[deps]\nCorset = \"$(Base.PkgId(Corset).uuid)\"\n")
            entries(link::String) = """
            manifest_format = "2.0"

            [[deps.A]]
            deps = ["B"]
            path = "../root"
            uuid = "$uuid"

            [[deps.B]]
            uuid = "$(Base.UUID(rand(UInt128)))"
            $link

            [[deps.Corset]]
            path = $(repr(corset))
            uuid = "$(Base.PkgId(Corset).uuid)"
            """
            project = joinpath(environment, "Project.toml")
            write_files(environment, "Project.toml" => "", "Manifest.toml" => entries("[deps.B.deps]\nCorset = \"$(Base.PkgId(Corset).uuid)\""))
            @test Cache.reaches_corset([project], realpath(root))
            write_files(environment, "Manifest.toml" => entries("deps = []"))
            @test !Cache.reaches_corset([project], realpath(root))
            # Corset as weak dependency triggers extension that can call rules.
            write_files(environment, "Manifest.toml" => entries("weakdeps = [\"Corset\"]"))
            @test Cache.reaches_corset([project], realpath(root))
            # Unknown reach counts as reach: package absent from load path, or project without Manifest.
            @test Cache.reaches_corset(String[], realpath(root)) && Cache.reaches_corset([joinpath(root, "Project.toml")], realpath(root))
            # Environment project at root starts from its own deps.
            write_files(root, "Manifest.toml" => entries("deps = []"))
            @test Cache.reaches_corset([joinpath(root, "Project.toml")], realpath(root))
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

    @testset "library key" begin
        julia = string(VERSION)
        @test Cache.partition_key(julia, DEPOT_PATH) == Cache.partition_key(julia, DEPOT_PATH) != Cache.partition_key("$julia+other", DEPOT_PATH)
        mktempdir(@__DIR__) do scratch
            depot, developed, environment = joinpath.(scratch, ["depot", "developed", "environment"])
            registered = joinpath(depot, "packages", "Registered", "slug")
            write_files(registered, "Project.toml" => "", "src/Registered.jl" => "module Registered end\n")
            write_files(developed, "Project.toml" => "", "src/Developed.jl" => "module Developed end\n", "test/runtests.jl" => "")
            ids = Base.PkgId(Base.UUID(rand(RandomDevice(), UInt128)), "Registered"), Base.PkgId(Base.UUID(rand(RandomDevice(), UInt128)), "Developed")
            contents()::Vector{String} = [Cache.package_content(id, root, [depot], "") for (id, root) in zip(ids, (registered, developed))]
            original = contents()
            # Depot slug derives from tree hash, so depot package counts by path; tests of path package never load.
            write_files(registered, "src/Registered.jl" => "module Registered f() = 1 end\n")
            write_files(developed, "test/runtests.jl" => "x = 1\n")
            @test contents() == original && startswith(first(original), "Registered $(ids[1].uuid) Registered/slug")
            other_depot = joinpath(scratch, "other_depot")
            other_registered = joinpath(other_depot, "packages", "Registered", "slug")
            write_files(other_registered, "Project.toml" => "", "src/Registered.jl" => "module Registered end\n")
            @test Cache.package_content(ids[1], other_registered, [other_depot], "") == original[1]
            write_files(developed, "src/Developed.jl" => "module Developed f() = 1 end\n")
            edited = contents()
            @test edited[1] == original[1] && edited[2] != original[2]
            # Skipped directory changes no content: rule edit keeps partition of Corset.
            rules = Cache.rule_sources(developed)
            skipping()::String = Cache.package_content(ids[2], developed, [depot], rules)
            write_files(developed, "src/rules/rule.jl" => "rule = 1\n")
            before = skipping()
            write_files(developed, "src/rules/rule.jl" => "rule = 2\n")
            @test skipping() == before && contents()[2] != edited[2]
            # Engine content skips rule sources the same way.
            engine = Cache.engine_content(developed, [depot])
            installed_engine = joinpath(depot, "packages", "Corset", "slug")
            mkpath(dirname(installed_engine))
            cp(developed, installed_engine; force = true)
            @test Cache.engine_content(installed_engine, [depot]) == engine
            write_files(developed, "src/rules/rule.jl" => "rule = 3\n")
            @test Cache.engine_content(developed, [depot]) == engine
            write_files(developed, "src/Engine.jl" => "engine = 1\n")
            @test Cache.engine_content(developed, [depot]) != engine
            # Preferences of package count too.
            write_files(environment, "Project.toml" => "[deps]\nDeveloped = \"$(ids[2].uuid)\"\n\n[preferences.Developed]\nmode = \"fast\"\n")
            push!(LOAD_PATH, environment)
            try
                @test endswith(contents()[2], "\nmode = \"fast\"\n")
            finally
                pop!(LOAD_PATH)
            end
        end
    end

    @testset "owner texts" begin
        texts(mod::Module)::Union{Nothing, Vector{String}} = Cache.owner_texts!(IdDict{Module, Union{Nothing, Vector{String}}}(), mod, DEPOT_PATH)
        # Julia version covers Base and Core; `Main` has no package root.
        @test texts(Base) == texts(Core) == texts(Base.Iterators) == String[] && isnothing(texts(Main))
        # Partition key holds content of Corset, so it gives texts of its dependencies only.
        own = something(texts(Corset))
        @test !any(startswith("Corset "), own) && any(startswith("Moshi "), own)
        mktempdir(@__DIR__) do scratch
            uuids = Dict(name => Base.UUID(rand(RandomDevice(), UInt128)) for name in ["Lib", "User", "Host", "Trigger", "Absent"])
            project(name::String, sections::String = "")::String = "name = \"$name\"\nuuid = \"$(uuids[name])\"\n$sections"
            roots = Dict(name => joinpath(scratch, name) for name in keys(uuids))
            write_files(roots["Lib"], "Project.toml" => project("Lib"), "src/Lib.jl" => "module Lib\nf(x) = x\nend\n")
            # Dependency that never loads adds no text.
            deps = "\n[deps]\nLib = \"$(uuids["Lib"])\"\nAbsent = \"$(uuids["Absent"])\"\n"
            write_files(roots["User"], "Project.toml" => project("User", deps), "src/User.jl" => "module User\nusing Lib: Lib\nend\n")
            extension = "\n[weakdeps]\nTrigger = \"$(uuids["Trigger"])\"\n\n[extensions]\nHostTriggerExt = \"Trigger\"\n"
            write_files(roots["Host"], "Project.toml" => project("Host", extension), "src/Host.jl" => "module Host\nf(x) = 1\nend\n")
            write_files(roots["Host"], "ext/HostTriggerExt.jl" => "module HostTriggerExt\nusing Host, Trigger\nHost.f(::Trigger.T) = 2\nend\n")
            write_files(roots["Trigger"], "Project.toml" => project("Trigger"), "src/Trigger.jl" => "module Trigger\nstruct T end\nend\n")
            append!(LOAD_PATH, [roots[name] for name in ["Lib", "User", "Host", "Trigger"]])
            loaded = try
                Dict(name => Base.require(Base.PkgId(uuids[name], name)) for name in ["Lib", "User", "Host", "Trigger"])
            finally
                filter!(path -> !startswith(path, scratch), LOAD_PATH)
            end
            lib, user = texts(loaded["Lib"]), texts(loaded["User"])
            @test length(lib) == 1 && startswith(only(lib), "Lib ") && sort!([lib; filter(startswith("User "), user)]) == user
            # Extension depends on its parent and trigger, and has no own text.
            hosted = something(Base.get_extension(loaded["Host"], :HostTriggerExt))
            @test texts(hosted) == sort!([texts(loaded["Host"]); texts(loaded["Trigger"])])
            # Root without project file or gone from disk has no texts, nor has package that depends on it.
            rm(joinpath(roots["Lib"], "Project.toml"))
            @test isnothing(texts(loaded["Lib"])) && isnothing(texts(loaded["User"]))
            rm(roots["Lib"]; recursive = true)
            @test isnothing(texts(loaded["Lib"]))
        end
    end

    @testset "shipped library shelf" begin
        mktempdir(@__DIR__) do scratch
            local_directory, shipped_directory = joinpath.(scratch, ["local", "shipped"])
            partition = "partition"
            entry = Cache.Stamped("instance", UInt8[1, 2], 0.0)
            Cache.with_database(shipped_directory) do db
                Cache.keep_library!(db, partition, Dict("key" => entry), Set{String}(), 100)
            end
            shipped_file = Cache.database_file(shipped_directory)
            before = read(shipped_file)
            Cache.with_database(shipped_directory) do shipped
                Cache.with_database(local_directory) do db
                    shelf = Cache.Shelf(db, partition, shipped)
                    @test !shelf.empty && Cache.shelf_holds(shelf, "key") && Cache.shelf_lists(shelf, "instance")
                    @test something(Cache.shelf_entry(shelf, "key")).bytes == entry.bytes
                    Cache.keep_library!(db, partition, Dict("key" => Cache.Stamped("local", UInt8[3], 0.0)), Set(["key"]), 100)
                    @test something(Cache.shelf_entry(shelf, "key")).bytes == UInt8[3]
                    Cache.keep_library!(db, partition, Dict{String, Cache.Stamped}(), Set{String}(), 0)
                    @test something(Cache.shelf_entry(shelf, "key")).bytes == entry.bytes
                    other = Cache.Shelf(db, "other", shipped)
                    @test other.empty && isnothing(Cache.shelf_entry(other, "key"))
                end
            end
            @test read(shipped_file) == before
        end
    end

    @testset "library partitions" begin
        mktempdir(@__DIR__) do scratch
            directory, partition = joinpath(scratch, "cache"), "partition"
            stamped(size::Int)::Cache.Stamped = Cache.Stamped("instance", fill(0x01, size), 0.0)
            keep!(found::Dict{String, Cache.Stamped}, hits::Set{String}, limit::Int, at::String)::Nothing = Cache.with_database(db -> Cache.keep_library!(db, at, found, hits, limit), directory)
            held(at::String)::Vector{Any} = cache_column(directory, "SELECT key FROM library WHERE partition = ? ORDER BY key", (at,))
            shelved(f::Function)::Any = Cache.with_database(db -> f(Cache.Shelf(db, partition)), directory)
            @test shelved(shelf -> shelf.empty)
            before = time()
            keep!(Dict("a" => stamped(10)), Set{String}(), 100, partition)
            a = shelved(shelf -> Cache.shelf_entry(shelf, "a"))
            @test held(partition) == ["a"] && a.used >= before && a.instance == "instance" && a.bytes == fill(0x01, 10)
            @test shelved(shelf -> !shelf.empty && Cache.shelf_holds(shelf, "a") && !Cache.shelf_holds(shelf, "b") && isnothing(Cache.shelf_entry(shelf, "b")))
            @test shelved(shelf -> Cache.shelf_lists(shelf, "instance") && !Cache.shelf_lists(shelf, "other"))
            # Entries go newest first within byte limit; hit makes entry new.
            sleep(0.05)
            keep!(Dict("b" => stamped(10)), Set{String}(), 100, partition)
            sleep(0.05)
            keep!(Dict("c" => stamped(10)), Set(["a", "absent"]), 25, partition)
            @test held(partition) == ["a", "c"]
            # Key breaks ties of time.
            keep!(Dict("e" => stamped(10), "d" => stamped(10)), Set{String}(), 15, partition)
            @test held(partition) == ["d"]
            # Hit of run without new entries makes entry new too; other partition holds none.
            used = shelved(shelf -> something(Cache.shelf_entry(shelf, "d")).used)
            sleep(0.05)
            keep!(Dict{String, Cache.Stamped}(), Set(["d"]), 100, partition)
            @test shelved(shelf -> something(Cache.shelf_entry(shelf, "d")).used) > used && isempty(held("other"))
            # Writer whose shelf opened before other write keeps entries of both.
            Cache.with_database(directory) do db
                shelf = Cache.Shelf(db, partition)
                keep!(Dict("f" => stamped(1)), Set{String}(), 100, partition)
                Cache.keep_library!(db, partition, Dict("g" => stamped(1)), Set{String}(), 100)
                @test Cache.shelf_holds(shelf, "f")
            end
            @test held(partition) == ["d", "f", "g"]
            # Database keeps newest partitions.
            for position in 1:Cache.LIBRARY_PARTITIONS
                sleep(0.05)
                keep!(Dict("x" => stamped(1)), Set{String}(), 100, "partition $position")
            end
            @test isempty(held(partition)) && all(position -> held("partition $position") == ["x"], 1:Cache.LIBRARY_PARTITIONS)
            # Write leaves default RNG alone (SQLite.jl `transaction` names savepoint with `randstring`).
            Random.seed!(7)
            expected = rand()
            Random.seed!(7)
            keep!(Dict("y" => stamped(1)), Set{String}(), 100, partition)
            @test rand() == expected
            # Throw inside write rolls it back.
            wipe(db::Cache.SQLite.DB)::Nothing = (Cache.DBInterface.execute(db, "DELETE FROM library"); error("stop"))
            @test_throws ErrorException Cache.with_database(db -> Cache.immediate(() -> wipe(db), db), directory)
            @test held(partition) == ["y"]
        end
    end

    @testset "entries" begin
        mktempdir(@__DIR__) do directory
            cache = joinpath(directory, "cache")
            # Reads of missing database make none.
            @test Cache.cold(cache, "/checked") && isnothing(Cache.lookup(String, cache, "/checked", "key")) && !isdir(cache)
            Cache.store!(cache, "/checked", "key", "first")
            Cache.store!(cache, "/checked", "key", "stored")
            @test !Cache.cold(cache, "/checked") && Cache.cold(cache, "/other")
            @test Cache.lookup(String, cache, "/checked", "key") == "stored"
            @test isnothing(Cache.lookup(String, cache, "/checked", "other key"))
            # Closed database leaves no journal file behind.
            @test readdir(cache) == ["cache.sqlite"] && Cache.stored_key(cache, "/checked") == "key"
            @test_throws TypeError Cache.lookup(Int, cache, "/checked", "key")
            # Database of other layout starts empty.
            cache_column(cache, "PRAGMA user_version = $(Cache.LAYOUT + 1)", ())
            @test Cache.cold(cache, "/checked")
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
            key = something(Cache.stored_key(cache, checked))
            Cache.store!(cache, checked, key, Corset.Engine.Analysis(checked, stored.files, [], [], [], []))
            @test isempty(Corset.check(directory; cache).diagnostics)
            @test Corset.Engine.baseline(directory; cache) == 0
            write(joinpath(directory, "a.jl"), "total = 1.0\ntotal ≈ 0\n\n")
            @test length(Corset.check(directory; cache).diagnostics) == 1
            @test Cache.stored_key(cache, checked) != key
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
                key, b = something(Cache.stored_key(cache, store_entry)), joinpath(realpath(package), "src", "b.jl")
                store = Cache.lookup(Corset.Inference.Store, cache, store_entry, key)
                # Entry of `second_part` that claims failing call shows store serves facts.
                held = first(name for (name, held) in store if first(held.file) == b)
                span = Corset.Facts.Span(b, 1, 11, Corset.Facts.Precision.exact)
                fake = Corset.Facts.FailingCall(span, span, "fake", Corset.Facts.Confidence.definite)
                bytes = Corset.Inference.serialized(Corset.Inference.Inferred(Union{}, Tuple{Type, Type}[], Type[], [1 => fake], true, false, Corset.Facts.Disruption[], Corset.Facts.HardArray[], Corset.Facts.NarrowingLoss[]))
                store[held] = Corset.Inference.Entry(store[held].file, store[held].methods, store[held].staged, bytes, store[held].effects)
                Cache.store!(cache, store_entry, key, store)
                write(joinpath(checked, "src", "a.jl"), first_part * "\n")
                @test occursin("call to `fake` never succeeds", cached_corset(cache, "check", package)[2])
                write(b, second_part * "\n")
                @test first(cached_corset(cache, "check", package)) == 0
                forget!(cache, store_entry)
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
