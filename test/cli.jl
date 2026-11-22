# Command-line tests: exit codes, output formats, fix, baseline and explain.

using Corset: Corset
using JSON: JSON
using JSONSchema: JSONSchema
using Scratch: Scratch
using Test: @test, @test_logs, @testset, @test_throws

include("helpers.jl")

const SARIF_SCHEMA = JSONSchema.Schema(JSON.parsefile(joinpath(@__DIR__, "fixtures", "sarif-schema-2.1.0.json")))

@testset "cli check" begin
    parsed = Corset.CLI.parse_args(["check", LIBRARY, "--effects"], Corset.CLI.argument_settings())
    @test parsed["check"]["effects"]
    parsed_kind = Corset.CLI.parse_args(["check", LIBRARY, "--kind", "library"], Corset.CLI.argument_settings())
    @test parsed_kind["check"]["kind"] == "library"
    forced = Corset.Config.settings(nothing, Corset.Config.Flags(; effects = true), Corset.Rules.REGISTRY)
    @test Corset.Engine.needs_effects(forced) && Corset.Engine.needs_inference(forced) && Corset.Engine.needs_package(forced)
    code, out, _ = corset("check", LIBRARY)
    @test code == 1 && occursin("error[approx-zero]", out) && endswith(out, "corset: 2 errors, 1 warning, 0 baselined\ncoverage: analyzed 2 files\n")
    @test first(corset("check", LIBRARY, "-A", "approx-zero")) == 0
    @test first(corset("check", LIBRARY, "-A", "approx-zero", "-D", "warnings")) == 1
    @test first(corset("check", LIBRARY, "--allow", "correctness", "--warn", "approx-zero")) == 0
    @test occursin("1 error, 2 warnings", corset("check", LIBRARY, "-W", "approx-zero", "-D", "untyped-empty")[2])
    for args in (("check", LIBRARY, "--format", "xml"), ("check", "no/such/path"), ("check", LIBRARY, "-D"), (), ("explain", "no-such-rule"))
        @test first(corset(args...)) == 2
    end
    @test first(corset("check", joinpath(@__DIR__, "config", "missing-kind"))) == 2
    @test first(redirect_stdout(() -> corset("--help"), devnull)) == 0
    @test redirect_stdout(() -> Corset.main(["explain", "baseline"]), devnull) == 0
end

@testset "cli script outside project" begin
    # System temp directory has no Project.toml above it, like standalone script.
    mktempdir() do directory
        @test isnothing(Corset.Config.project_root(directory))
        script = joinpath(directory, "script.jl")
        write(script, "const WORKERS = Threads.nthreads()\nreach(value::Real)::Bool = value ≈ 0\ntask = @async reach(1)\nENV[\"MODE\"] = \"fast\"\n")
        for target in (script, directory)
            code, out, _ = corset("check", target, "-W", "composability")
            @test code == 1 && occursin("error[approx-zero]", out) && occursin("coverage: analyzed 1 file", out)
            @test !any(rule -> occursin(rule, out), ("baked-state", "pinned-task", "process-state"))
        end
    end
end

@testset "cli formats" begin
    json = JSON.parse(corset("check", LIBRARY, "--format", "json", "--confidence", "possible")[2])
    @test json["version"] == 1 && json["baselined"] == 0 && isempty(json["stale"])
    @test [entry["rule"] for entry in json["diagnostics"]] == ["untyped-empty", "approx-zero", "approx-zero"]
    first_label = json["diagnostics"][1]["labels"][1]
    @test (first_label["file"], first_label["line"], first_label["column"], first_label["end_column"]) == ("a.jl", 2, 10, 12)
    sarif = JSON.parse(corset("check", LIBRARY, "--format", "sarif")[2])
    @test isnothing(JSONSchema.validate(SARIF_SCHEMA, sarif))
    @test [result["level"] for result in only(sarif["runs"])["results"]] == ["warning", "error", "error"]
    computed = "\"\"\"Computed include.\"\"\"\nmodule Computed\ninclude(string(\"part\", \".jl\"))\nend\n"
    with_package(@__DIR__, "Computed", "src/Computed.jl" => computed, "src/part.jl" => "part_value = 1\n") do package
        coverage = JSON.parse(corset("check", package, "--format", "json")[2])["coverage"]
        @test coverage["files"] == 1 && only(coverage["blind_spots"])["cause"] == "include with computed path"
        sarif = JSON.parse(corset("check", package, "--format", "sarif")[2])
        @test isnothing(JSONSchema.validate(SARIF_SCHEMA, sarif))
        @test only(only(only(sarif["runs"])["invocations"])["toolExecutionNotifications"])["message"]["text"] == "skipped: include with computed path"
    end
end

@testset "fix of loaded package asks for fresh check" begin
    mktempdir(@__DIR__) do root
        uuid = Base.UUID(rand(UInt128))
        write(joinpath(root, "Project.toml"), "name = \"RecheckSample\"\nuuid = \"$uuid\"\n\n[preferences.Corset]\nkind = \"library\"\n")
        mkpath(joinpath(root, "src"))
        source = joinpath(root, "src", "RecheckSample.jl")
        write(source, "module RecheckSample\n\"\"\"Half of `x`.\"\"\"\nhalf(x::AbstractFloat)::AbstractFloat = x * 0.5\nend\n")
        push!(LOAD_PATH, root)
        try
            code, out, err = corset("fix", root)
            @test code == Corset.CLI.EXIT_RECHECK && isempty(out) && startswith(err, "corset: applied ")
            @test occursin("oftype(x, 0.5)", read(source, String))
            # No edit leaves loaded methods current, so same process reports.
            @test first(corset("fix", root)) in (Corset.CLI.EXIT_PASS, Corset.CLI.EXIT_FAIL)
        finally
            pop!(LOAD_PATH)
        end
    end
end

@testset "cli fix, baseline, explain" begin
    mktempdir(@__DIR__) do directory
        write(joinpath(directory, "Project.toml"), "[deps]\n")
        write(joinpath(directory, "a.jl"), "f(x::T)::T where T = x\nreach(value::Real)::Bool = value ≈ 0\n")
        sarif = JSON.parse(corset("check", directory, "--format", "sarif", "-A", "one-letter")[2])
        @test isnothing(JSONSchema.validate(SARIF_SCHEMA, sarif))
        @test any(!isempty(result["fixes"]) for result in only(sarif["runs"])["results"])
        code, _, err = corset("fix", directory, "--tier", "safe")
        @test occursin("applied 1 edits", err) && code == 1
        @test startswith(read(joinpath(directory, "a.jl"), String), "(f(x::T)::T) where T = x\n")
        @test occursin("wrote 1 findings", corset("baseline", directory, "-A", "one-letter")[3])
        @test first(corset("check", directory, "-A", "one-letter")) == 0
        write(joinpath(directory, "a.jl"), "x = 1\n")
        stale = corset("check", directory, "--format", "sarif", "-A", "one-letter")
        @test first(stale) == 1 && isnothing(JSONSchema.validate(SARIF_SCHEMA, JSON.parse(stale[2])))
        @test occursin("error[baseline]", corset("check", directory, "-A", "one-letter")[2])
        symlink(joinpath(directory, "missing.jl"), joinpath(directory, "broken.jl"))
        @test first(corset("check", directory)) == 101
    end
    code, out, _ = corset("explain", "approx-zero")
    @test code == 0 && startswith(out, "approx-zero (correctness group, syntax stage, F10)")
    @test occursin("opt-outs that suppress nothing", corset("explain", "opt-out")[2])
    @test all(first(corset("explain", string(entry.name))) == 0 for entry in Corset.Rules.REGISTRY)
    @test occursin("Run `corset baseline`", corset("explain", "baseline")[2])
    @test occursin("no level, opt-out or baseline hides", corset("explain", "parse-error")[2])
end

@testset "parse errors" begin
    mktempdir(@__DIR__) do directory
        write(joinpath(directory, "Project.toml"), "[deps]\n")
        # Missing token: empty diagnostic range widens to byte there. Error at end of file: last byte.
        write(joinpath(directory, "a.jl"), "first_value = (1 2)\nsecond_value = 1 +\n")
        code, out, _ = corset("check", directory, "-A", "readability")
        @test code == 1 && count("error[parse-error]: code does not parse", out) == 2
        @test occursin("parse check, always on", out) && !occursin("allow parse-error", out)
        @test occursin("wrote 0 findings", corset("baseline", directory, "-A", "readability")[3])
        @test first(corset("check", directory, "-A", "readability")) == 1
        sarif = JSON.parse(corset("check", directory, "--format", "sarif")[2])
        @test isnothing(JSONSchema.validate(SARIF_SCHEMA, sarif))
    end
end

@testset "load errors" begin
    throws = "\"\"\"Package that throws at load.\"\"\"\nmodule Throws\ninclude(\"inner.jl\")\nend\n"
    files = ("src/Throws.jl" => throws, "src/inner.jl" => "helper() = error(\"boom at load\")\nhelper()\n", "src/notes.jl" => "note = 1\n")
    with_package(@__DIR__, "Throws", files...) do package
        code, out, _ = corset("check", package)
        @test code == 1 && occursin("error[load-error]: package does not load\n --> src/inner.jl:1:1", out)
        @test occursin("boom at load", out) && occursin("load check, always on", out) && occursin("skipped 1 (package did not load: 1)", out)
        # Run that allows every rule after `syntax` stage loads nothing.
        allow_package = reduce(vcat, (["-A", string(entry.name)] for entry in Corset.Rules.REGISTRY if entry.fix_stage != Corset.Facts.Stage.syntax))
        @test !occursin("load-error", corset("check", package, allow_package...)[2])
        # Checked file leaves out entry and frames: span falls back to entry file, read from disk.
        @test occursin("--> src/Throws.jl:1:1", corset("check", joinpath(package, "src", "notes.jl"))[2])
        other = mktempdir(@__DIR__)
        cp(package, other; force = true)
        code, _, err = corset("check", other)
        @test code == 2 && occursin("loads Throws from $(joinpath(package, "src", "Throws.jl"))", err)
        rm(other; recursive = true)
    end
    # `jl_generating_output` is 1 only while precompiling, so second load in anonymous module succeeds.
    precompile_only = "\"\"\"Package that fails only while precompiling.\"\"\"\nmodule PrecompileOnly\nccall(:jl_generating_output, Cint, ()) == 1 && error(\"precompile only\")\nend\n"
    with_package(@__DIR__, "PrecompileOnly", "src/PrecompileOnly.jl" => precompile_only) do package
        code, out, _ = redirect_stderr(() -> corset("check", package), devnull)
        @test code == 1 && occursin("--> src/PrecompileOnly.jl:1:1", out) && occursin("failed to precompile", out)
    end
    init_fails = "\"\"\"Package whose `__init__` throws.\"\"\"\nmodule InitFails\n__init__() = error(\"init failed\")\nend\n"
    # Test process loads JSON 1, so pin of 0.21 counts as blind spot even when package fails to load.
    pinned = "manifest_format = \"2.0\"\n\n[[deps.JSON]]\nuuid = \"682c06a0-de6a-54ab-a142-c8b1cf79cde6\"\nversion = \"0.21.0\"\n"
    with_package(@__DIR__, "InitFails", "src/InitFails.jl" => init_fails, "Manifest.toml" => pinned) do package
        out = corset("check", package)[2]
        @test occursin("--> src/InitFails.jl:3:1", out) && occursin("init failed", out)
        @test occursin("analyzed 1 file; skipped 2 (loaded version differs from Manifest: 1, package did not load: 1)", out)
        # Manifest holds blind spot, so it is source, but JSON counts analyzed files only.
        @test JSON.parse(corset("check", package, "--format", "json")[2])["coverage"]["files"] == 1
    end
    mktempdir(@__DIR__) do package
        mkpath(joinpath(package, "src"))
        write(joinpath(package, "src", "Lost.jl"), "\"\"\"Package off load path.\"\"\"\nmodule Lost\nend\n")
        write(joinpath(package, "Project.toml"), "name = \"Lost\"\n\n[preferences.Corset]\nkind = \"library\"\n")
        code, _, err = corset("check", package)
        @test code == 2 && occursin("needs valid uuid", err)
        write(joinpath(package, "Project.toml"), "name = \"Lost\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\n\n[preferences.Corset]\nkind = \"library\"\n")
        code, _, err = corset("check", package)
        @test code == 2 && occursin("environment cannot load Lost", err)
    end
    # Second load resolves `using` as package does: Helper is dependency of Outer only, not of environment.
    mktempdir(@__DIR__) do root
        outer, helper = Base.UUID(rand(UInt128)), Base.UUID(rand(UInt128))
        manifest = "manifest_format = \"2.0\"\n\n[[deps.Outer]]\ndeps = [\"Helper\"]\npath = \"../Outer\"\nuuid = \"$outer\"\n\n[[deps.Helper]]\npath = \"../Helper\"\nuuid = \"$helper\"\n"
        files = [
            "Outer/src/Outer.jl" => "module Outer\nusing Helper: Helper\nerror(\"after dependency\")\nend\n", "Helper/src/Helper.jl" => "module Helper\nend\n",
            "env/Project.toml" => "[deps]\nOuter = \"$outer\"\n", "env/Manifest.toml" => manifest,
        ]
        for (path, text) in files
            mkpath(dirname(joinpath(root, path)))
            write(joinpath(root, path), text)
        end
        pushfirst!(LOAD_PATH, joinpath(root, "env", "Project.toml"))
        error = try
            first(Corset.Package.reproduce(joinpath(root, "Outer", "src", "Outer.jl"), Base.PkgId(outer, "Outer")))
        finally
            popfirst!(LOAD_PATH)
        end
        cause = Corset.Package.unwrapped(error)
        @test cause isa ErrorException && cause.msg == "after dependency"
    end
    @test occursin("Reports package or extension", corset("explain", "load-error")[2])
end

@testset "stages see package methods" begin
    # Package loads during `execute`, after it starts; type-disruption converts `THIRD` with package `Float32` method.
    newer = """
    \"\"\"Package whose number type converts only through its own methods.\"\"\"
    module Newer
    \"\"\"One third.\"\"\"
    struct Third <: AbstractIrrational end
    Base.Float32(::Third) = 1.0f0 / 3
    Base.Float64(::Third) = 1 / 3
    const THIRD = Third()
    \"\"\"`x` when `y` has its type; `2.0` otherwise.\"\"\"
    paired(x::T, y::T) where {T} = x
    paired(x, y) = 2.0
    \"\"\"`2.0`, since `THIRD` has no float type.\"\"\"
    scaled(x::Real) = paired(x, THIRD)
    end
    """
    with_package(@__DIR__, "Newer", "src/Newer.jl" => newer) do package
        _, out, err = corset("check", package)
        @test occursin("warning[type-disruption]", out) && occursin("THIRD", out) && isempty(err)
        # Crash journal changes no finding; run without crash leaves only finished records.
        mktempdir() do directory
            journaled = IOBuffer()
            Corset.CLI.execute(["check", package], journaled, IOBuffer(); launch = false, cache = nothing, journal = directory)
            written = Corset.Inference.records(directory)
            @test String(take!(journaled)) == out && !isempty(written) && isempty(Corset.Inference.crashed(written))
        end
    end
end

@testset "extensions" begin
    trigger, absent, failing = Base.UUID(rand(UInt128)), Base.UUID(rand(UInt128)), Base.UUID(rand(UInt128))
    project = """
    name = "Extended"
    uuid = "$(Base.UUID(rand(UInt128)))"

    [weakdeps]
    Absent = "$absent"
    Failing = "$failing"
    Trigger = "$trigger"

    [extensions]
    AbsentExt = "Absent"
    BrokenExt = "Trigger"
    FailingExt = "Failing"
    PrecompileOnlyExt = "Trigger"
    TriggerExt = ["Trigger"]

    [preferences.Corset]
    kind = "library"
    """
    files = [
        "Project.toml" => project,
        "src/Extended.jl" => "\"\"\"Package with extensions.\"\"\"\nmodule Extended\n\"\"\"Number in box.\"\"\"\nstruct Box\n    number::Int\nend\nend\n",
        "ext/AbsentExt.jl" => "module AbsentExt\nend\n",
        "ext/FailingExt.jl" => "module FailingExt\nend\n",
        "ext/BrokenExt.jl" => "module BrokenExt\nusing Extended, Trigger\nerror(\"extension boom\")\nend\n",
        "ext/PrecompileOnlyExt.jl" => "module PrecompileOnlyExt\nccall(:jl_generating_output, Cint, ()) == 1 && error(\"precompile only\")\nend\n",
        "ext/TriggerExt/TriggerExt.jl" => "module TriggerExt\nusing Extended: Box\nlength(box::Box)::Int = box.number\nend\n",
        "trigger/Project.toml" => "name = \"Trigger\"\nuuid = \"$trigger\"\n",
        "trigger/src/Trigger.jl" => "module Trigger\nend\n",
        "failing/Project.toml" => "name = \"Failing\"\nuuid = \"$failing\"\n",
        "failing/src/Failing.jl" => "module Failing\nerror(\"trigger boom\")\nend\n",
    ]
    mktempdir(@__DIR__) do root
        for (path, text) in files
            mkpath(dirname(joinpath(root, path)))
            write(joinpath(root, path), text)
        end
        append!(LOAD_PATH, [root, joinpath(root, "trigger"), joinpath(root, "failing")])
        try
            code, out, _ = redirect_stderr(() -> corset("check", root), devnull)
            @test code == 1 && occursin("error[shadowed-base]: `length` defines new function", out) && occursin("--> ext/TriggerExt/TriggerExt.jl:3:1", out)
            @test occursin("error[load-error]: extension `BrokenExt` does not load\n --> ext/BrokenExt.jl:3:1", out) && occursin("extension boom", out)
            @test occursin("extension `PrecompileOnlyExt` failed to precompile; Julia logged error", out)
            @test occursin("skipped 4 (extension did not load: 2, extension trigger did not load: 1, extension trigger not installed: 1)", out)
            @test occursin("ext/AbsentExt.jl:1:1: extension trigger not installed", out)
            @test occursin("ext/FailingExt.jl:1:1: extension trigger did not load", out)
            # Checked path leaves extension files out: they are read from disk for report.
            @test occursin("ext/AbsentExt.jl:1:1", redirect_stderr(() -> corset("check", joinpath(root, "src")), devnull)[2])
        finally
            filter!(path -> !startswith(path, root), LOAD_PATH)
        end
        write(joinpath(root, "Project.toml"), replace(project, "TriggerExt = [\"Trigger\"]" => "TriggerExt = [\"Trigger\", \"Lost\"]"))
        @test_throws "extension TriggerExt names Lost, which [weakdeps] lacks" Corset.Discovery.project_facts(root; environment = nothing)
    end
end

@testset "external stage" begin
    ambiguous = "\"\"\"Package with ambiguous methods.\"\"\"\nmodule Ambiguous\ncombine(left::Int, right) = left\ncombine(left, right::Int) = right\nbody(type::Type) = Base.unwrap_unionall(type)\ninclude(\"side.jl\")\nend\n"
    side = "side(value::Int)::Int = value\n"
    with_package(@__DIR__, "Ambiguous", "src/Ambiguous.jl" => ambiguous, "src/side.jl" => side) do package
        code, out, _ = corset("check", package)
        @test code == 1 && occursin("error[method-ambiguity]: `combine(::Int64, ::Int64)` matches two methods", out)
        @test occursin("warning[internal-access]: `Base.unwrap_unionall` is internal to `Base`\n --> src/Ambiguous.jl:5:25", out)
        # Access in file outside checked path drops.
        @test !occursin("internal-access", corset("check", joinpath(package, "src", "side.jl"))[2])
        # External checks run only when some `external` rule is enabled.
        external(flags::Corset.Config.Flags) = first(Corset.Engine.analyze(Corset.Engine.inputs(package, flags)..., nothing, nothing)).external
        @test length(external(Corset.Config.Flags()).ambiguities) == 1
        allowed = [string(entry.name) => Corset.Config.Level.allow for entry in Corset.Rules.REGISTRY if entry.stage == Corset.Facts.Stage.external]
        @test length(allowed) > 1 && isnothing(external(Corset.Config.Flags(; levels = allowed)))
        @test !isnothing(external(Corset.Config.Flags(; levels = allowed[2:end])))
        # Path through symlink finds same method sites.
        mktempdir(@__DIR__) do directory
            link = joinpath(directory, "link")
            symlink(package, link)
            @test corset("check", link)[2] == out
        end
    end
end

@testset "relaunch inputs" begin
    Launch, Discovery, TestDeps = Corset.Launch, Corset.Discovery, Corset.Facts.TestDeps
    uuid = Base.UUID(rand(UInt128))
    mktempdir(@__DIR__) do root
        project = "name = \"Targets\"\nuuid = \"$uuid\"\n\n[deps]\nJSON = \"682c06a0-de6a-54ab-a142-c8b1cf79cde6\"\n\n[weakdeps]\nTOML = \"fa267f1f-6049-4f14-aa54-33bafae1ed76\"\n\n[extras]\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n"
        write(joinpath(root, "Project.toml"), project)
        @test_throws "package Targets has no module file src/Targets.jl" Discovery.project_facts(root; environment = nothing)
        mkpath(joinpath(root, "src"))
        write(joinpath(root, "src", "Targets.jl"), "module Targets\nend\n")
        facts = Discovery.project_facts(root; environment = nothing)
        @test facts.test_deps == TestDeps.none && isempty(Launch.test_specs(facts)) && isempty(Launch.manifest_deps(joinpath(root, "Project.toml")))
        @test Corset.Package.package_id(facts) == Base.PkgId(uuid, "Targets") && [dep.name for dep in facts.deps] == ["JSON"]
        # `[targets].test` skips direct dependencies and reads names from `[weakdeps]` and `[extras]`.
        write(joinpath(root, "Project.toml"), project * "\n[targets]\ntest = [\"JSON\", \"TOML\", \"Test\"]\n")
        facts = Discovery.project_facts(root; environment = nothing)
        @test facts.test_deps == TestDeps.target && [spec.name for spec in Launch.test_specs(facts)] == ["TOML", "Test"]
        # `[targets].test` reads `[sources]` of Project.toml; Corset test dependency gives way to running Corset.
        corset = "\nCorset = \"$(Base.PkgId(Corset).uuid)\"\n\n[sources]\nTest = {path = \"vendor/Test\"}\nCorset = {url = \"https://example.com/Corset.jl\"}\n"
        write(joinpath(root, "Project.toml"), project * corset * "\n[targets]\ntest = [\"Corset\", \"Test\"]\n")
        @test only(Launch.test_specs(Discovery.project_facts(root; environment = nothing))).path == joinpath(root, "vendor", "Test")
        write(joinpath(root, "Project.toml"), project * "\n[targets]\ntest = [\"Lost\"]\n")
        @test_throws "test target names Lost, which [extras] lacks" Discovery.project_facts(root; environment = nothing)
        # `test/Project.toml` drops package and direct dependencies, and reads `[sources]` relative to its own directory.
        write(joinpath(root, "Project.toml"), project)
        mkpath(joinpath(root, "test"))
        helper, remote, branch, mono = (Base.UUID(rand(UInt128)) for _ in 1:4)
        tests = """
        [deps]
        Targets = "$uuid"
        JSON = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
        Helper = "$helper"
        Remote = "$remote"
        Branch = "$branch"
        Mono = "$mono"

        [sources]
        Targets = {path = ".."}
        Helper = {path = "../helper"}
        Remote = {url = "https://example.com/Remote.jl", rev = "main"}
        Branch = {rev = "dev"}
        Mono = {url = "https://example.com/Mono.jl", subdir = "lib/Mono"}
        """
        write(joinpath(root, "test", "Project.toml"), tests)
        facts = Discovery.project_facts(root; environment = nothing)
        branch_spec, helper_spec, mono_spec, remote_spec = specs = Launch.test_specs(facts)
        @test facts.test_deps == TestDeps.project && [spec.name for spec in specs] == ["Branch", "Helper", "Mono", "Remote"]
        @test helper_spec.path == joinpath(root, "helper") && remote_spec.url == "https://example.com/Remote.jl" && remote_spec.rev == "main"
        @test isnothing(branch_spec.url) && branch_spec.rev == "dev" && mono_spec.subdir == "lib/Mono"
        # Manifest paths become absolute; format 1 Manifest is config error.
        write(joinpath(root, "Manifest.toml"), "manifest_format = \"2.0\"\n\n[[deps.Helper]]\npath = \"helper\"\nuuid = \"$helper\"\n")
        @test only(Launch.manifest_deps(joinpath(root, "Project.toml"))["Helper"])["path"] == joinpath(root, "helper")
        # Cache key reads Project.toml of each path dependency: Manifest entry `Local`, test source `Helper`.
        write(joinpath(root, "Manifest.toml"), "manifest_format = \"2.0\"\n\n[[deps.Local]]\npath = \"local\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\n")
        for directory in ("local", "helper")
            key = Launch.cache_key(facts)
            mkpath(joinpath(root, directory))
            write(joinpath(root, directory, "Project.toml"), "name = \"Changed\"\n")
            @test Launch.cache_key(facts) != key
        end
        write(joinpath(root, "Manifest.toml"), "[[Helper]]\npath = \"helper\"\nuuid = \"$helper\"\n")
        @test_throws "has format 1" Launch.manifest_deps(joinpath(root, "Project.toml"))
        # Test loads: transitive `[deps]` of package and tests; Manifest maps name to uuid where names repeat.
        environment = joinpath(root, "env", "Project.toml")
        mkpath(dirname(environment))
        write(environment, "")
        @test isnothing(Discovery.test_loads(environment, uuid, Base.PkgId[]))
        shared, other = Base.UUID(rand(UInt128)), Base.UUID(rand(UInt128))
        manifest = """
        manifest_format = "2.0"

        [[deps.Targets]]
        deps = ["Helper"]
        uuid = "$uuid"

        [[deps.Helper]]
        uuid = "$helper"

        [[deps.Remote]]
        uuid = "$remote"

            [deps.Remote.deps]
            Shared = "$shared"

        [[deps.Shared]]
        uuid = "$shared"

        [[deps.Shared]]
        uuid = "$other"

        [[deps.Mono]]
        uuid = "$mono"
        """
        write(joinpath(root, "env", "Manifest.toml"), manifest)
        loads = Discovery.test_loads(environment, uuid, [Base.PkgId(remote, "Remote"), Base.PkgId(Base.UUID(rand(UInt128)), "Ghost")])
        @test [id.name for id in loads] == ["Helper", "Remote", "Shared", "Targets"] && Base.PkgId(shared, "Shared") in loads
        @test isnothing(Discovery.test_loads(environment, Base.UUID(rand(UInt128)), Base.PkgId[]))
        @test [id.name for id in Discovery.project_facts(root; environment).test_loads] == ["Helper", "Mono", "Remote", "Shared", "Targets"]
    end
    @test Corset.CLI.exit_code(run(ignorestatus(`sh -c 'exit 3'`))) == 3
    @test Corset.CLI.exit_code(run(ignorestatus(`sh -c "kill -KILL \$\$"`))) == 101
end

@testset "untracked relaunch" begin
    tracked = `$(Base.julia_cmd()) --code-coverage=user --track-allocation=user`
    options = "print(Base.JLOptions().code_coverage, Base.JLOptions().malloc_log)"
    @test read(`$tracked --startup-file=no -e $options`, String) == "11"
    @test read(`$(Corset.Launch.untracked(tracked)) --startup-file=no -e $options`, String) == "00"
end

@testset "manifest moves" begin
    Launch, Package = Corset.Launch, Corset.Package
    textwrap, syntax = Base.UUID("b718987f-49a8-5099-9789-dcd902bef87d"), Base.UUID("70703baa-626e-46a2-a12c-08ffd08c73b4")
    tiers = Launch.unpin_tiers()
    @test length(tiers) == 3 && isempty(tiers[1]) && syntax in tiers[2] && textwrap ∉ tiers[2] && textwrap in tiers[3] && tiers[2] ⊆ tiers[3]
    entry(uuid, version...) = Dict{String, Any}("uuid" => uuid, ("version" => v for v in version)...)
    pinned = Dict{String, Any}("A" => [entry("a", "1.0.0")], "B" => [entry("b", "2.0.0")], "C" => [entry("c")], "D" => [entry("d", "1.0.0")])
    used = Dict{String, Any}("A" => [entry("a", "1.1.0")], "B" => [entry("b", "2.0.0")], "C" => [entry("c", "3.0.0")])
    @test Launch.moves(pinned, used) == [("A", "1.0.0", "1.1.0")]
    @test Launch.freed(Dict{String, Any}("TextWrap" => [entry(string(textwrap))], "Other" => [entry(string(Base.UUID(rand(UInt128))))]), Set([textwrap, syntax])) == Set([textwrap])
    mktempdir(@__DIR__) do root
        json, argus = Base.PkgId(Base.UUID("682c06a0-de6a-54ab-a142-c8b1cf79cde6"), "JSON"), Base.PkgId(Base.UUID("e39743ec-b2cc-45ef-a990-b666fc093538"), "Argus")
        write(joinpath(root, "Project.toml"), "name = \"Moved\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\n")
        manifest = """
        manifest_format = "2.0"

        [[deps.Argus]]
        uuid = "$(argus.uuid)"
        version = "$(pkgversion(Base.loaded_modules[argus]))"

        [[deps.JSON]]
        uuid = "$(json.uuid)"
        version = "0.21.0"

        [[deps.Ghost]]
        uuid = "$(Base.UUID(rand(UInt128)))"
        version = "1.0.0"

        [[deps.TOML]]
        uuid = "fa267f1f-6049-4f14-aa54-33bafae1ed76"

        [[deps."EnumX"]]
        uuid = "4e289a0a-7415-4d19-859d-a7e5c4648b56"
        version = "0.0.1"
        """
        write(joinpath(root, "Manifest.toml"), manifest)
        project = Corset.Facts.ProjectFacts("Moved", nothing, root, "", Base.PkgId[], Corset.Facts.Extension[], Corset.Facts.TestDeps.none, Base.PkgId[], nothing)
        spots = Package.moved_versions(project)
        header = first(findfirst("[[deps.JSON]]", manifest))
        @test [(spot.cause, spot.span.first_byte, spot.span.last_byte) for spot in spots] == [("loaded version differs from Manifest", 1, 1), ("loaded version differs from Manifest", header, header + 12)]
        rm(joinpath(root, "Manifest.toml"))
        @test isempty(Package.moved_versions(project))
    end
end

@testset "relaunch" begin
    # Packages sit off test load path, so only relaunched process can load them.
    mktempdir(@__DIR__) do scratch
        Scratch.with_scratch_directory(scratch) do
            launched(args::String...) = (out = IOBuffer(); err = IOBuffer(); code = Corset.CLI.execute(String[args...], out, err; launch = true, cache = Corset.Cache.directory()); (code, String(take!(out)), String(take!(err))))
            box = "\"\"\"Package only relaunched process loads.\"\"\"\nmodule Relaunched\n\"\"\"Number in box.\"\"\"\nstruct Box\n    number::Int\nend\nlength(box::Box)::Int = box.number\nend\n"
            mktempdir(@__DIR__) do root
                uuid, helper = Base.UUID(rand(UInt128)), Base.UUID(rand(UInt128))
                files = [
                    "Project.toml" => "name = \"Relaunched\"\nuuid = \"$uuid\"\n\n[weakdeps]\nDates = \"ade2ca70-3891-5945-98fb-dc099432e06a\"\n\n[extensions]\nDatesExt = \"Dates\"\n\n[preferences.Corset]\nkind = \"library\"\n",
                    "src/Relaunched.jl" => box,
                    # Helper loads Dates, so tests load extension Dates triggers.
                    "helper/Project.toml" => "name = \"Helper\"\nuuid = \"$helper\"\n\n[deps]\nDates = \"ade2ca70-3891-5945-98fb-dc099432e06a\"\n",
                    "helper/src/Helper.jl" => "module Helper\nusing Dates: Dates\nend\n",
                    "ext/DatesExt.jl" => "\"\"\"Extension tests load through Helper.\"\"\"\nmodule DatesExt\nend\n",
                    "test/Project.toml" => "[deps]\nHelper = \"$helper\"\nRelaunched = \"$uuid\"\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n\n[sources]\nHelper = {path = \"../helper\"}\nRelaunched = {path = \"..\"}\n",
                ]
                for (path, text) in files
                    mkpath(dirname(joinpath(root, path)))
                    write(joinpath(root, path), text)
                end
                @test occursin("environment cannot load Relaunched", corset("check", root)[3])
                code, out, err = launched("check", root, "-A", "annotation")
                @test code == 1 && occursin("error[shadowed-base]", out) && !occursin("annotation", out) && !occursin("untested-extension", out)
                @test occursin("building environment for Relaunched", err) && occursin("no cached analysis", err)
                # Relaunched process stored analysis under key relaunching process computes, so repeat run loads nothing.
                flags = Corset.Config.Flags(; levels = ["annotation" => Corset.Config.Level.allow])
                env = Corset.Launch.environment(Corset.Engine.load_target(root, flags), IOBuffer())
                @test !isnothing(Corset.Engine.cached(root, flags, Corset.Cache.directory(), Corset.Launch.load_path(env)))
                @test launched("check", root, "-A", "annotation") == (code, out, "")
                @test launched("baseline", root, "-A", "annotation") == (0, "", "corset: wrote 1 findings to $(Corset.Baseline.FILE)\n")
                rm(joinpath(root, Corset.Baseline.FILE))
                # Fix writes files, so it relaunches even when cache holds analysis. Report comes from fresh process:
                # process that fixed holds `Relaunched.length` from before edit.
                # `--tier` belongs to `fix` only, so check that follows drops it.
                code, out, err = launched("fix", root, "-A", "annotation", "--tier", "breaking")
                @test startswith(err, "corset: applied 1 edits\n") && code == 0 && !occursin("shadowed-base", out)
                code, out, err = launched("check", root, "-A", "shadowed-base")
                @test code == 0 && !occursin("building environment", err)
            end
            mktempdir(@__DIR__) do root
                write(joinpath(root, "Project.toml"), "name = \"Noisy\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\n")
                mkpath(joinpath(root, "src"))
                write(joinpath(root, "src", "Noisy.jl"), "module Noisy\n__init__() = println(\"noisy initialization\")\nend\n")
                report_file = joinpath(scratch, "noisy-report.json")
                code, out, _ = launched("check", root, "--kind", "library", "--format", "json", "--output", report_file)
                @test code in (0, 1) && occursin("noisy initialization", out)
                @test JSON.parsefile(report_file)["coverage"]["files"] > 0
            end
            # Generator aborts Julia on float stand-in, as Enzyme generator does; rerun skips that inference.
            crashing = """
            \"\"\"Package whose generator aborts Julia on float stand-in.\"\"\"
            module Crashing
            \"\"\"`x`; generator aborts process for float stand-in.\"\"\"
            @generated function generated(x)
                nameof(x) === :FloatStandIn && ccall(:abort, Cvoid, ())
                return :(x)
            end
            \"\"\"`x` plus one, through generated function.\"\"\"
            outer(x::Real) = generated(x) + 1
            end
            """
            mktempdir(@__DIR__) do root
                write(joinpath(root, "Project.toml"), "name = \"Crashing\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\n\n[preferences.Corset]\nkind = \"library\"\n")
                mkpath(joinpath(root, "src"))
                write(joinpath(root, "src", "Crashing.jl"), crashing)
                code, out, err = launched("check", root)
                @test code == 0 && occursin("corset: Julia crashed inferring Crashing.outer at Crashing.jl:9; running again without it", err)
                @test occursin("inference crashed process: 1", out) && !occursin("signal", err)
                report = last(split(only(filter(contains("Report: "), split(err, '\n'))), "Report: "))
                @test occursin("signal", read(report, String))
                # Stale lock of dead run clears at once, well before waiting attempt checks staleness.
                # Age between stale age and 5 times it: dead pid alone makes lock stale.
                target = something(Corset.Engine.load_target(root, Corset.Config.Flags()))
                env = Corset.Launch.environment(target, IOBuffer())
                write("$env.pid", "$(typemax(Int32)) $(gethostname())")
                run(`touch -d @$(round(Int, time()) - 2 * Corset.Launch.LOCK_STALE_SECONDS) $env.pid`)
                @test_logs (:warn, r"stale pidfile") begin
                    waiting = @async Corset.Launch.environment(target, IOBuffer())
                    @test timedwait(() -> istaskdone(waiting), Corset.Launch.LOCK_STALE_SECONDS / 3) === :ok && fetch(waiting) == env && !isfile("$env.pid")
                end
                # Lock of live run holds until its holder releases it.
                release = Channel{Nothing}(1)
                holder = @async Corset.Launch.locked(() -> take!(release), "$env.pid")
                @test timedwait(() -> isfile("$env.pid"), 10) === :ok
                waiting = @async Corset.Launch.environment(target, IOBuffer())
                sleep(1)
                @test !istaskdone(waiting)
                put!(release, nothing)
                @test timedwait(() -> istaskdone(waiting), 30) === :ok && fetch(waiting) == env && istaskdone(holder)
                # Crash past limit throws.
                @test_throws "over limit 0" Corset.Launch.supervise(env, ["check", root], nothing, IOBuffer(), IOBuffer(), 0)
            end
            # Manifest pins TextWrap 0.3; Corset needs ArgParse 1, which needs TextWrap 1. Compat bound blocks move.
            for compat in ("", "\n[compat]\nTextWrap = \"0.3\"\n")
                mktempdir(@__DIR__) do root
                    textwrap = "b718987f-49a8-5099-9789-dcd902bef87d"
                    write(joinpath(root, "Project.toml"), "name = \"Pinned\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\n\n[deps]\nTextWrap = \"$textwrap\"\n$compat\n[preferences.Corset]\nkind = \"library\"\n")
                    write(joinpath(root, "Manifest.toml"), "manifest_format = \"2.0\"\n\n[[deps.TextWrap]]\ngit-tree-sha1 = \"8355cc559e85469cd4dbe927c375f61d3750e002\"\nuuid = \"$textwrap\"\nversion = \"0.3.0\"\n")
                    mkpath(joinpath(root, "src"))
                    write(joinpath(root, "src", "Pinned.jl"), "\"\"\"Package with old Manifest.\"\"\"\nmodule Pinned\nend\n")
                    code, out, err = launched("check", root)
                    if isempty(compat)
                        @test code == 0 && occursin("corset: Manifest pins TextWrap 0.3.0; environment uses 1.", err)
                        @test occursin("coverage: analyzed 1 file; skipped 1 (loaded version differs from Manifest: 1)", out) && occursin("  - Manifest.toml:3:1: loaded version differs from Manifest", out)
                    else
                        @test code == 2 && occursin("cannot build environment for Pinned from its Manifest, even with Corset dependencies moved", err) && occursin("TextWrap", err)
                    end
                end
            end
        end
    end
end

@testset "precompile workload" begin
    mktempdir(@__DIR__) do directory
        @test isnothing(Corset.workload(directory))
        @test isfile(joinpath(directory, "corset-baseline.toml"))
        write(joinpath(directory, "corset-baseline.toml"), "not toml")
        @test_throws "exited with 2" Corset.workload(directory)
    end
end

@testset "package workload" begin
    @test isnothing(Corset.package_workload())
    # Sample code must run: inference stops at call that always throws, so package image keeps less.
    sample = Corset.PackageSample
    @test sample.area(sample.Disk(2)) ≈ 4π
    @test sample.arithmetic(1.5, 2) isa Real
    @test sample.integers(7, 2) isa Integer
    @test sample.reductions([1, 2, 3]) == 39
    @test length(sample.transforms([3.0, -1.0], 2)) == 10
    @test sample.matrices([1 2; 3 4]) == 20
    @test sample.apply(abs, -1) == 3
    @test sample.describe(1.234) == "value: 1.23 of Float64"
    @test collect(sample.Countdown(3)) == [3, 2, 1]
    @test sample.Ones(2) == [1.0, 1.0]
    @test length(sample.literals()) == 13
    # Every literal value type JuliaSyntax produces appears in sample, so workload compiles each literal lookup.
    path = joinpath(pkgdir(Corset), "src", "PackageSample.jl")
    tree = Corset.Syntax.parse_file(path, read(path, String), Corset.Facts.Role.package).tree
    spelled = Set(typeof(node.val) for node in Corset.Facts.descendants(tree) if Corset.Syntax.JS.is_literal(node))
    @test [Int64, Int128, BigInt, UInt8, UInt16, UInt32, UInt64, UInt128, Float32, Float64, Bool, Char, String] ⊆ spelled
end

@testset "fix conflicts" begin
    span(first, last) = Corset.Facts.Span("f.jl", first, last, Corset.Facts.Precision.exact)
    fix(first, last) = Corset.Facts.Fix("t", [Corset.Facts.Edit(span(first, last), "x")], Corset.Facts.Tier.safe)
    finding(first, last) = Corset.Facts.Finding(:sample, :kind, Corset.Facts.Confidence.definite, "m", Corset.Facts.Label(span(first, last), "l"), Corset.Facts.Label[], "w", fix(first, last))
    edits = Corset.Fixes.applicable_edits([finding(1, 3), finding(2, 4), finding(5, 6)], Corset.Facts.Tier.safe)
    @test [edit.span.first_byte for edit in edits] == [1, 5]
end

@testset "output path" begin
    mktempdir(@__DIR__) do scratch
        script, link, report = joinpath.(scratch, ["script.jl", "link.jl", "report.txt"])
        write(script, "x = 1\n")
        symlink(script, link)
        # Output on analyzed source, also through symbolic link, fails and keeps source.
        for target in (script, link)
            code, _, err = corset("check", script, "--output", target)
            @test code == 2 && occursin("analyzed source", err) && read(script, String) == "x = 1\n"
        end
        @test first(corset("check", script, "--output", report)) in (0, 1) && isfile(report)
    end
end
