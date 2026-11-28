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
            write_files(dependency, "src/D.jl" => "module D end\n", "out.json" => "{}")
            gone = "\n[[deps.Gone]]\npath = \"../gone\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\n"
            corset = realpath(pkgdir(Corset))
            developed = "\n[[deps.Corset]]\npath = $(repr(corset))\nuuid = \"$(Base.PkgId(Corset).uuid)\"\n"
            manifest = "manifest_format = \"2.0\"\n\n[[deps.D]]\npath = \"../dependency\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\n$gone$developed"
            write_files(environment, "Project.toml" => "", "Manifest.toml" => manifest)
            script, link = joinpath(scratch, "script.jl"), joinpath(scratch, "link.jl")
            write(script, "x = 1\n")
            symlink(script, link)
            project = joinpath(environment, "Project.toml")
            parts, files, naming = Cache.inputs(root, "flags", root, [joinpath(root, "src", "a.jl"), link], [project, Sys.STDLIB], joinpath(root, "cache"))
            @test parts == [string(VERSION), repr(Base.CacheFlags()), "@root", "flags", "@environment1/Project.toml", Sys.STDLIB]
            names = ["Project.toml", "Manifest.toml", "LocalPreferences.toml", "JuliaLocalPreferences.toml"]
            @test naming.anchors == [realpath(root) => "@root"; [Cache.real_path(joinpath(environment, name)) => "@environment1/$name" for name in names]]
            # Entry relocates root alone: file near environment keeps real path in key.
            @test Cache.anchored(joinpath(realpath(environment), "deps", "D.jl"), naming.anchors) == joinpath(realpath(environment), "deps", "D.jl")
            @test naming.manifests == Set([realpath(joinpath(environment, "Manifest.toml"))])
            listed = [
                joinpath(root, "Project.toml"), joinpath(root, "src", "a.jl"), script, joinpath(dependency, "src", "D.jl"), joinpath(dependency, "out.json"),
                project, joinpath(environment, "Manifest.toml"), joinpath(environment, "LocalPreferences.toml"), joinpath(environment, "JuliaLocalPreferences.toml"),
                joinpath(corset, "Project.toml"), joinpath(corset, "src", "Cache.jl"),
            ]
            @test issubset(listed, files) && issorted(files) && allunique(files)
            @test !any(file -> file in (joinpath(root, ".hidden"), link) || startswith(file, joinpath(scratch, "gone")), files)
            # Developed Corset counts by project file and source: depot and outputs in its root change no Corset code.
            @test !(joinpath(corset, "test", "cache.jl") in files)
            # Manifest format 1 keeps entries at top level.
            write_files(environment, "Manifest.toml" => "[[D]]\npath = \"../dependency\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\n")
            @test Cache.path_entries(project) == [dependency]
            # Script outside project counts only its own files.
            @test !any(startswith(root), Cache.inputs(script, "flags", nothing, [script], String[], joinpath(scratch, "cache"))[2])
        end
    end

    @testset "relocated key" begin
        # Copy of project and environment in other directory gives same key; Manifest develops root by real path.
        mktempdir() do scratch
            uuid = Base.UUID(rand(RandomDevice(), UInt128))
            function copy_key(name::String, text::String, own::Bool = false)::Tuple{String, Union{Nothing, String}}
                root, environment = joinpath.(scratch, name, ["root", "environment"])
                real = (mkpath(root); realpath(root))
                # Malformed fixture named `Manifest.toml` counts by bytes: only environment Manifest parses.
                write_files(root, "Project.toml" => "", "src/a.jl" => text, "test/fixtures/Manifest.toml" => "[[")
                write_files(environment, "Project.toml" => "", "Manifest.toml" => "manifest_format = \"2.0\"\n\n[[deps.A]]\npath = \"$real\"\nuuid = \"$uuid\"\n")
                # Environment of `own` copy is project itself.
                project = joinpath(own ? real : environment, "Project.toml")
                return Cache.key(joinpath(real, "src"), "flags", real, [joinpath(real, "src", "a.jl")], [project, Sys.STDLIB], joinpath(scratch, "cache"))
            end
            original, relocated = copy_key("first", "a = 1\n")
            @test relocated == realpath(joinpath(scratch, "first", "root"))
            @test original == first(copy_key("second", "a = 1\n")) != first(copy_key("third", "a = 2\n"))
            # Code that names own root can act on it: key names root and entry relocates nothing. Unchanged copy elsewhere
            # names other root, so it keys apart.
            text = "a = (@__DIR__) == \"$(realpath(mkpath(joinpath(scratch, "fourth", "root"))))/src\"\n"
            named, copied = copy_key("fourth", text), copy_key("fifth", text)
            @test isnothing(last(named)) && first(named) != first(copied) && !isnothing(last(copied))
            # Files hash in order of anchored name: copies on either side of shared environment key alike.
            shared = joinpath(scratch, "m", "Project.toml")
            write_files(dirname(shared), "Project.toml" => "")
            sides = map(["a", "z"]) do name
                real = realpath(mkpath(joinpath(scratch, name, "root")))
                write_files(real, "Project.toml" => "", "src/a.jl" => "a = 1\n")
                return Cache.key(joinpath(real, "src"), "flags", real, [joinpath(real, "src", "a.jl")], [shared, Sys.STDLIB], joinpath(scratch, "cache"))
            end
            @test first(sides[1]) == first(sides[2])
            # Project environment around unanchored root keeps root in key: copies that name both roots key apart.
            both = text * "b = (@__DIR__) == \"$(realpath(mkpath(joinpath(scratch, "fifth", "root"))))/src\"\n"
            @test first(copy_key("fourth", both, true)) != first(copy_key("fifth", both, true))
            # Anchor names whole directory: sibling that shares prefix stays absolute.
            anchors = ["/p/root" => "@root"]
            @test [Cache.anchored(path, anchors) for path in ["/p/root", "/p/root/a.jl", "/p/root2/a.jl"]] == ["@root", "@root/a.jl", "/p/root2/a.jl"]
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
            key(shape::Vector{String}, files::Vector{String}, project::String = joinpath(environment, "Project.toml"))::String =
                Cache.method_key(root, root, files, shape, [project], joinpath(root, "cache"))
            original = key(["shape"], analyzed)
            # Relaunch runs in new temporary copy of environment each time: copy keys alike.
            copied = cp(environment, joinpath(scratch, "copied"))
            @test key(["shape"], analyzed, joinpath(copied, "Project.toml")) == original
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

    @testset "producer source" begin
        # Store and library keys read producer files only, so module that producer imports must be producer too.
        source = joinpath(Cache.corset_root(), "src")
        files = Cache.producer_files(source, Cache.PRODUCERS)
        producers = Set(first(splitext(first(splitpath(relpath(file, source))))) for file in files)
        @test Set(found[1] for file in files for found in eachmatch(r"\.\.+([A-Z]\w*)", read(file, String))) ⊆ producers
        @test "Inference" in producers && "Effects" in producers && isdisjoint(producers, ("Rules", "Engine", "CLI", "Launch"))
        @test joinpath(source, "Inference", "failures.jl") in files && Cache.producer_digest() == Cache.producer_digest()
        mktempdir(@__DIR__) do scratch
            write_files(scratch, "A.jl" => "include(\"A/b.jl\")\n", "A/b.jl" => "b = 1\n", "C.jl" => "")
            original = Cache.producer_digest(scratch, ("A.jl",))
            # File no entry includes stays out; included file counts by content.
            write_files(scratch, "C.jl" => "c = 1\n")
            @test Cache.producer_digest(scratch, ("A.jl",)) == original
            write_files(scratch, "A/b.jl" => "b = 2\n")
            @test Cache.producer_digest(scratch, ("A.jl",)) != original
            write_files(scratch, "A.jl" => "include(name)\n")
            @test_throws ArgumentError Cache.producer_files(scratch, ("A.jl",))
        end
    end

    @testset "library key" begin
        julia = string(VERSION)
        @test Cache.partition_key(julia) == Cache.partition_key(julia) != Cache.partition_key("$julia+other")
        mktempdir(@__DIR__) do scratch
            depot, developed, environment = joinpath.(scratch, ["depot", "developed", "environment"])
            registered = joinpath(depot, "packages", "Registered", "slug")
            write_files(registered, "Project.toml" => "", "src/Registered.jl" => "module Registered end\n")
            write_files(developed, "Project.toml" => "", "src/Developed.jl" => "module Developed end\n", "test/runtests.jl" => "")
            ids = Base.PkgId(Base.UUID(rand(RandomDevice(), UInt128)), "Registered"), Base.PkgId(Base.UUID(rand(RandomDevice(), UInt128)), "Developed")
            contents()::Vector{String} = [Cache.package_content(id, root, [depot]) for (id, root) in zip(ids, (registered, developed))]
            original = contents()
            # Depot slug derives from tree hash, so depot package counts by path; tests of path package never load.
            write_files(registered, "src/Registered.jl" => "module Registered f() = 1 end\n")
            write_files(developed, "test/runtests.jl" => "x = 1\n")
            @test contents() == original && startswith(first(original), "Registered $(ids[1].uuid) $registered")
            write_files(developed, "src/Developed.jl" => "module Developed f() = 1 end\n")
            edited = contents()
            @test edited[1] == original[1] && edited[2] != original[2]
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

    @testset "library file" begin
        mktempdir(@__DIR__) do scratch
            directory, partition = joinpath(scratch, "library"), "partition"
            stamped(size::Int)::Cache.Stamped = Cache.Stamped("instance", fill(0x01, size), 0.0)
            keep!(found::Dict{String, Cache.Stamped}, hits::Set{String}, limit::Int)::Nothing = Cache.keep_library!(directory, partition, found, hits, limit)
            # Run without entries writes nothing.
            keep!(Dict{String, Cache.Stamped}(), Set{String}(), 100)
            @test !isdir(directory) && isempty(Cache.read_library(directory, partition))
            before = time()
            keep!(Dict("a" => stamped(10)), Set{String}(), 100)
            first_read = Cache.read_library(directory, partition)
            @test only(keys(first_read)) == "a" && first_read["a"].used >= before && first_read["a"].instance == "instance"
            # Entries go newest first within byte limit; hit makes entry new.
            sleep(0.05)
            keep!(Dict("b" => stamped(10)), Set{String}(), 100)
            sleep(0.05)
            keep!(Dict("c" => stamped(10)), Set(["a", "absent"]), 25)
            @test Set(keys(Cache.read_library(directory, partition))) == Set(["a", "c"])
            # Key breaks ties of time.
            keep!(Dict("e" => stamped(10), "d" => stamped(10)), Set{String}(), 15)
            @test collect(keys(Cache.read_library(directory, partition))) == ["d"]
            # Run without new entries marks file as used; other partition reads none.
            file = Cache.entry(directory, partition)
            mtime_before = mtime(file)
            sleep(0.05)
            keep!(Dict{String, Cache.Stamped}(), Set(["d"]), 100)
            @test mtime(file) > mtime_before && isempty(Cache.read_library(directory, "other"))
            # Directory keeps newest library files; staging file of other process stays.
            staging, io = mktemp(directory)
            close(io)
            for position in 1:Cache.LIBRARY_FILES
                sleep(0.05)
                Cache.keep_library!(directory, "partition $position", Dict("x" => stamped(1)), Set{String}(), 100)
            end
            @test !isfile(file) && isfile(staging) && all(position -> isfile(Cache.entry(directory, "partition $position")), 1:Cache.LIBRARY_FILES)
        end
    end

    @testset "entries" begin
        mktempdir(@__DIR__) do directory
            cache = joinpath(directory, "cache")
            @test Cache.cold(cache, "/checked") && isnothing(Cache.lookup(String, cache, "/checked", "key"; root = nothing))
            Cache.store!(cache, "/checked", "key", "first"; root = nothing)
            Cache.store!(cache, "/checked", "key", "stored"; root = nothing)
            @test !Cache.cold(cache, "/checked") && Cache.cold(cache, "/other")
            @test Cache.lookup(String, cache, "/checked", "key"; root = nothing) == "stored"
            @test isnothing(Cache.lookup(String, cache, "/checked", "other key"; root = nothing))
            # Entry is file per name; no staging file stays behind.
            @test readdir(cache) == [basename(Cache.entry(cache, "/checked"))]
            @test_throws TypeError Cache.lookup(Int, cache, "/checked", "key"; root = nothing)
            # Hit makes entry new for `prune!`; miss leaves it old.
            file = Cache.entry(cache, "/checked")
            handle = Base.Filesystem.open(file, Base.Filesystem.JL_O_RDONLY)
            Base.Filesystem.futime(handle, 0.0, 0.0)
            close(handle)
            @test isnothing(Cache.lookup(String, cache, "/checked", "other key"; root = nothing)) && mtime(file) == 0
            @test Cache.lookup(String, cache, "/checked", "key"; root = nothing) == "stored" && mtime(file) > 0
            # Only missing entry is miss: cache path that names file fails loud.
            @test_throws Base.IOError Cache.lookup(String, file, "/checked", "key"; root = nothing)
        end
    end

    @testset "relocating entries" begin
        mktempdir() do directory
            shared = "/a/b/shared path"
            paths = ["/a/b", "/a/b/c.jl", "cannot load /a/b/d.jl here", "/a/bc/e.jl", "/x/a/b", shared, shared]
            Cache.store!(directory, "name", "key", paths; root = "/a/b")
            moved = Cache.lookup(Vector{String}, directory, "name", "key"; root = "/q")
            @test moved == ["/q", "/q/c.jl", "cannot load /q/d.jl here", "/a/bc/e.jl", "/x/a/b", "/q/shared path", "/q/shared path"]
            # Entry holds mark in place of root: read without root keeps it.
            @test Cache.lookup(Vector{String}, directory, "name", "key"; root = nothing)[2] == Cache.ROOT_MARK * "/c.jl"
            # Root that relocation cannot reach fails loud and stores nothing.
            @test_throws ErrorException Cache.store!(directory, "symbol", "key", [Symbol("/a/b/c.jl")]; root = "/a/b")
            @test_throws ErrorException Cache.store!(directory, "substring", "key", [SubString("/a/b/c.jl", 1)]; root = "/a/b")
            # Root with pattern syntax and other script matches literally.
            odd = "/a/\\E(é) [b]*"
            Cache.store!(directory, "odd", "key", [odd * "/c.jl", "/a/xE(é) [b]*/c.jl"]; root = odd)
            @test Cache.lookup(Vector{String}, directory, "odd", "key"; root = "/q") == ["/q/c.jl", "/a/xE(é) [b]*/c.jl"]
            @test Cache.cold(directory, "symbol") && Cache.cold(directory, "substring")
        end
    end

    @testset "prune" begin
        mktempdir() do directory
            names = [bytes2hex(rand(RandomDevice(), UInt8, 16)) for _ in 1:3]
            for name in names
                write(joinpath(directory, name), fill(0x01, 10))
                sleep(0.05)
            end
            mkpath(joinpath(directory, "library"))
            write(joinpath(directory, "staging"), fill(0x01, 100))
            # Hit makes entry new: oldest entry goes first.
            touch(joinpath(directory, names[1]))
            Cache.prune!(directory, 25)
            @test sort!(readdir(directory)) == sort!([names[1], names[3], "library", "staging"])
            # Newest entry stays past limit.
            Cache.prune!(directory, 0)
            @test sort!(readdir(directory)) == sort!([names[1], "library", "staging"])
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
            # Stored analysis serves check: entry with no diagnostics hides finding. Entry is named by key.
            entry = only(readdir(cache; join = true))
            key = readline(entry)
            @test entry == Cache.entry(cache, key)
            Cache.store!(cache, key, key, Corset.Engine.Analysis(checked, stored.files, [], [], [], []); root = checked)
            @test isempty(Corset.check(directory; cache).diagnostics)
            @test Corset.Engine.baseline(directory; cache) == 0
            write(joinpath(directory, "a.jl"), "total = 1.0\ntotal ≈ 0\n\n")
            @test length(Corset.check(directory; cache).diagnostics) == 1
            @test length(readdir(cache)) == 2
        end
        # Copy of project in other directory takes entry of original, with paths below copy.
        mktempdir() do scratch
            cache, original, copied = joinpath.(scratch, ["cache", "original", "copied"])
            write_files(original, "Project.toml" => "[deps]\n", "a.jl" => "total = 1.0\ntotal ≈ 0\n")
            found = Corset.check(original; cache).diagnostics
            cp(original, copied)
            moved = realpath(copied)
            _, stored = something(Corset.Engine.cached(copied, Flags(), cache, Base.load_path()))
            @test stored.root == moved && stored.files == [joinpath(moved, "a.jl")]
            @test only(stored.leveled).finding.primary.span.file == joinpath(moved, "a.jl")
            relocated = Corset.check(copied; cache).diagnostics
            @test [diagnostic.finding.message for diagnostic in relocated] == [diagnostic.finding.message for diagnostic in found]
            @test length(readdir(cache)) == 1
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
            entries = readdir(cache)
            @test cached_corset(cache, "check", other, "--no-cache") == (code, out, "")
            @test readdir(cache) == entries
            # Fix through cache matches fix without it.
            fixed, plain = cached_corset(cache, "fix", directory), corset("fix", other)
            @test fixed[1:2] == plain[1:2] && read(joinpath(directory, "a.jl"), String) == read(joinpath(other, "a.jl"), String)
        end
        # Rerun after edit takes facts of unchanged files from method store. New method drops only entries that call its function.
        entry = "\"\"\"Package with two files.\"\"\"\nmodule Stored\ninclude(\"a.jl\")\ninclude(\"b.jl\")\nend\n"
        first_part, second_part = "first_part(x::Real) = x + 1\n", "second_part(x::Real) = x * 2\nthird_part(x::Real) = first_part(x)\n"
        with_package(@__DIR__, "Stored", "src/Stored.jl" => entry, "src/a.jl" => first_part, "src/b.jl" => second_part) do package
            mktempdir(@__DIR__) do cache
                @test first(cached_corset(cache, "check", package)) == 0
                checked, store_entry = realpath(package), Corset.Engine.method_entry(realpath(package))
                key, b = readline(Cache.entry(cache, store_entry)), joinpath(realpath(package), "src", "b.jl")
                store = Cache.lookup(Corset.Inference.Store, cache, store_entry, key; root = nothing)
                # Entries of `b.jl` that claim failing call show store serves facts: `fake` for `second_part`, `faker` for `third_part`.
                span = Corset.Facts.Span(b, 1, 11, Corset.Facts.Precision.exact)
                for (name, held) in store
                    first(held.file) == b || continue
                    callee = any(==("call Stored.first_part") ∘ first, held.names) ? "faker" : "fake"
                    fake = Corset.Facts.FailingCall(span, span, callee, Corset.Facts.Confidence.definite)
                    bytes = Corset.Inference.serialized(Corset.Inference.Inferred(Union{}, Tuple{Type, Type}[], Type[], [1 => fake], true, false, Corset.Facts.Disruption[], Corset.Facts.HardArray[], Corset.Facts.NarrowingLoss[], Corset.Facts.StatefulIterate[]))
                    store[name] = Corset.Inference.Entry(held.file, held.methods, held.staged, held.names, bytes, held.effects)
                end
                Cache.store!(cache, store_entry, key, store; root = nothing)
                # New method of `first_part` and new function: `third_part` infers again, `second_part` keeps its entry.
                # Rerun in process keeps loaded module (`Base.require`), so new lines run in it at their file lines.
                # Rerun of old line would overwrite its method (`method-overwrite`).
                added, a = "first_part(x::Int) = x - 1\nunrelated(x::Int) = x\n", joinpath(checked, "src", "a.jl")
                write(a, first_part * added)
                include_string(Base.root_module(Base.identify_package("Stored")), "\n" * added, a)
                rerun = cached_corset(cache, "check", package)[2]
                @test occursin("call to `fake` never succeeds", rerun) && !occursin("call to `faker` never succeeds", rerun)
                write(b, second_part * "\n")
                @test first(cached_corset(cache, "check", package)) == 0
                rm(Cache.entry(cache, store_entry))
                write(b, second_part)
                @test first(cached_corset(cache, "check", package, "--no-cache")) == 0 && Cache.cold(cache, store_entry)
            end
        end
        # Package run: blind spots and load problems come back from cache.
        # Load skips include in branch, so it stays blind spot.
        computed = "\"\"\"Package with computed include.\"\"\"\nmodule Cached\nif get(ENV, \"CORSET_PART\", \"\") == \"1\"\n    include(string(\"part\", \".jl\"))\nend\nend\n"
        with_package(@__DIR__, "Cached", "src/Cached.jl" => computed, "src/part.jl" => "part_value = 1\n") do package
            mktempdir(@__DIR__) do cache
                first = cached_corset(cache, "check", package)
                @test occursin("skipped 1", first[2]) && cached_corset(cache, "check", package) == (first[1], first[2], "")
            end
            # `--timings` on cold cache times store reads and writes too; hit times lookup only.
            mktempdir(@__DIR__) do cache
                cold = cached_corset(cache, "check", package, "--timings")
                stages = [
                    "cache lookup", "discovery", "cache lookup", "package load", "method store read", "library read", "inference", "effects",
                    "method store update", "lifecycle", "method store write", "library write", "external", "rules", "cache write",
                ]
                @test occursin("skipped 1", cold[2]) && timing_rows(cold[3]) == stages
                @test timing_rows(cached_corset(cache, "check", package, "--timings")[3]) == ["cache lookup"]
            end
        end
    end
end
