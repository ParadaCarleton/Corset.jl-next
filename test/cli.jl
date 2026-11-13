# Command-line tests: exit codes, output formats, fix, baseline and explain.

using Corset: Corset
using JSON: JSON
using JSONSchema: JSONSchema
using Scratch: Scratch
using Test: @test, @testset

"""Exit code, standard output and standard error of `corset args...`."""
function corset(args::String...)::Tuple{Int, String, String}
    out, err = IOBuffer(), IOBuffer()
    code = Corset.CLI.execute(String[args...], out, err; launch = false)
    return code, String(take!(out)), String(take!(err))
end

const LIBRARY = joinpath(@__DIR__, "config", "library")
# Package stage loads fixture packages in place, so test environment must load them from their roots.
LIBRARY in LOAD_PATH || push!(LOAD_PATH, LIBRARY)

"""Run `body` on new package `name` written under `parent` from `files` (path => text), with package on load path."""
function with_package(body::Function, parent::String, name::String, files::Pair{String, String}...)::Nothing
    mktempdir(parent) do package
        write(joinpath(package, "Project.toml"), "name = \"$name\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\n\n[preferences.Corset]\nkind = \"library\"\n")
        for (path, text) in files
            mkpath(dirname(joinpath(package, path)))
            write(joinpath(package, path), text)
        end
        push!(LOAD_PATH, package)
        try
            body(package)
        finally
            pop!(LOAD_PATH)
        end
    end
    return nothing
end
const SARIF_SCHEMA = JSONSchema.Schema(JSON.parsefile(joinpath(@__DIR__, "fixtures", "sarif-schema-2.1.0.json")))

@testset "cli check" begin
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
        @test occursin("boom at load", out) && occursin("load check, always on", out) && occursin("skipped 1 (1 package did not load)", out)
        @test !occursin("load-error", corset("check", package, "-A", "shadowed-base")[2])
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
    with_package(@__DIR__, "InitFails", "src/InitFails.jl" => init_fails) do package
        out = corset("check", package)[2]
        @test occursin("--> src/InitFails.jl:3:1", out) && occursin("init failed", out)
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
    @test occursin("Reports package or extension", corset("explain", "load-error")[2])
end

@testset "extensions" begin
    trigger, absent = Base.UUID(rand(UInt128)), Base.UUID(rand(UInt128))
    project = """
    name = "Extended"
    uuid = "$(Base.UUID(rand(UInt128)))"

    [weakdeps]
    Absent = "$absent"
    Trigger = "$trigger"

    [extensions]
    AbsentExt = "Absent"
    BrokenExt = "Trigger"
    PrecompileOnlyExt = "Trigger"
    TriggerExt = ["Trigger"]

    [preferences.Corset]
    kind = "library"
    """
    files = [
        "Project.toml" => project,
        "src/Extended.jl" => "\"\"\"Package with extensions.\"\"\"\nmodule Extended\n\"\"\"Number in box.\"\"\"\nstruct Box\n    number::Int\nend\nend\n",
        "ext/AbsentExt.jl" => "module AbsentExt\nend\n",
        "ext/BrokenExt.jl" => "module BrokenExt\nusing Extended, Trigger\nerror(\"extension boom\")\nend\n",
        "ext/PrecompileOnlyExt.jl" => "module PrecompileOnlyExt\nccall(:jl_generating_output, Cint, ()) == 1 && error(\"precompile only\")\nend\n",
        "ext/TriggerExt/TriggerExt.jl" => "module TriggerExt\nusing Extended: Box\nlength(box::Box)::Int = box.number\nend\n",
        "trigger/Project.toml" => "name = \"Trigger\"\nuuid = \"$trigger\"\n",
        "trigger/src/Trigger.jl" => "module Trigger\nend\n",
    ]
    mktempdir(@__DIR__) do root
        for (path, text) in files
            mkpath(dirname(joinpath(root, path)))
            write(joinpath(root, path), text)
        end
        append!(LOAD_PATH, [root, joinpath(root, "trigger")])
        try
            code, out, _ = redirect_stderr(() -> corset("check", root), devnull)
            @test code == 1 && occursin("error[shadowed-base]: `length` defines new function", out) && occursin("--> ext/TriggerExt/TriggerExt.jl:3:1", out)
            @test occursin("error[load-error]: extension `BrokenExt` does not load\n --> ext/BrokenExt.jl:3:1", out) && occursin("extension boom", out)
            @test occursin("extension `PrecompileOnlyExt` failed to precompile; Julia logged error", out)
            @test occursin("skipped 3 (2 extension did not load, 1 extension trigger not installed)", out)
            @test occursin("ext/AbsentExt.jl:1:1: extension trigger not installed", out)
            # Checked path leaves extension files out: they are read from disk for report.
            @test occursin("ext/AbsentExt.jl:1:1", redirect_stderr(() -> corset("check", joinpath(root, "src")), devnull)[2])
        finally
            filter!(path -> !startswith(path, root), LOAD_PATH)
        end
        write(joinpath(root, "Project.toml"), replace(project, "TriggerExt = [\"Trigger\"]" => "TriggerExt = [\"Trigger\", \"Lost\"]"))
        @test_throws "extension TriggerExt names Lost, which [weakdeps] lacks" Corset.Package.extension_triggers(root)
    end
end

@testset "relaunch inputs" begin
    Launch = Corset.Launch
    uuid = Base.UUID(rand(UInt128))
    id = Base.PkgId(uuid, "Targets")
    mktempdir(@__DIR__) do root
        project = "name = \"Targets\"\nuuid = \"$uuid\"\n\n[deps]\nJSON = \"682c06a0-de6a-54ab-a142-c8b1cf79cde6\"\n\n[weakdeps]\nTOML = \"fa267f1f-6049-4f14-aa54-33bafae1ed76\"\n\n[extras]\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n"
        write(joinpath(root, "Project.toml"), project)
        @test isempty(Launch.test_specs(root, id)) && isempty(Launch.manifest_deps(joinpath(root, "Project.toml")))
        # `[targets].test` skips direct dependencies and reads names from `[weakdeps]` and `[extras]`.
        write(joinpath(root, "Project.toml"), project * "\n[targets]\ntest = [\"JSON\", \"TOML\", \"Test\"]\n")
        @test [spec.name for spec in Launch.test_specs(root, id)] == ["TOML", "Test"]
        write(joinpath(root, "Project.toml"), project * "\n[targets]\ntest = [\"Lost\"]\n")
        @test_throws "test target names Lost, which [extras] lacks" Launch.test_specs(root, id)
        # `test/Project.toml` drops target and reads `[sources]` relative to its own directory.
        write(joinpath(root, "Project.toml"), project)
        mkpath(joinpath(root, "test"))
        helper, remote = Base.UUID(rand(UInt128)), Base.UUID(rand(UInt128))
        tests = "[deps]\nTargets = \"$uuid\"\nHelper = \"$helper\"\nRemote = \"$remote\"\n\n[sources]\nTargets = {path = \"..\"}\nHelper = {path = \"../helper\"}\nRemote = {url = \"https://example.com/Remote.jl\", rev = \"main\"}\n"
        write(joinpath(root, "test", "Project.toml"), tests)
        specs = Launch.test_specs(root, id)
        @test [spec.name for spec in specs] == ["Helper", "Remote"]
        @test specs[1].path == joinpath(root, "helper") && specs[2].url == "https://example.com/Remote.jl" && specs[2].rev == "main"
        # Manifest paths become absolute; format 1 Manifest is config error.
        write(joinpath(root, "Manifest.toml"), "manifest_format = \"2.0\"\n\n[[deps.Helper]]\npath = \"helper\"\nuuid = \"$helper\"\n")
        @test only(Launch.manifest_deps(joinpath(root, "Project.toml"))["Helper"])["path"] == joinpath(root, "helper")
        write(joinpath(root, "Manifest.toml"), "[[Helper]]\npath = \"helper\"\nuuid = \"$helper\"\n")
        @test_throws "has format 1" Launch.manifest_deps(joinpath(root, "Project.toml"))
    end
    @test Corset.CLI.exit_code(run(ignorestatus(`sh -c 'exit 3'`))) == 3
    @test Corset.CLI.exit_code(run(ignorestatus(`sh -c "kill -KILL \$\$"`))) == 101
end

@testset "relaunch" begin
    # Packages sit off test load path, so only relaunched process can load them.
    mktempdir(@__DIR__) do scratch
        Scratch.with_scratch_directory(scratch) do
            launched(args::String...) = (out = IOBuffer(); err = IOBuffer(); code = Corset.CLI.execute(String[args...], out, err; launch = true); (code, String(take!(out)), String(take!(err))))
            box = "\"\"\"Package only relaunched process loads.\"\"\"\nmodule Relaunched\n\"\"\"Number in box.\"\"\"\nstruct Box\n    number::Int\nend\nlength(box::Box)::Int = box.number\nend\n"
            mktempdir(@__DIR__) do root
                uuid, helper = Base.UUID(rand(UInt128)), Base.UUID(rand(UInt128))
                files = [
                    "Project.toml" => "name = \"Relaunched\"\nuuid = \"$uuid\"\n\n[preferences.Corset]\nkind = \"library\"\n",
                    "src/Relaunched.jl" => box,
                    "helper/Project.toml" => "name = \"Helper\"\nuuid = \"$helper\"\n",
                    "helper/src/Helper.jl" => "module Helper\nend\n",
                    "test/Project.toml" => "[deps]\nHelper = \"$helper\"\nRelaunched = \"$uuid\"\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n\n[sources]\nHelper = {path = \"../helper\"}\nRelaunched = {path = \"..\"}\n",
                ]
                for (path, text) in files
                    mkpath(dirname(joinpath(root, path)))
                    write(joinpath(root, path), text)
                end
                @test occursin("environment cannot load Relaunched", corset("check", root)[3])
                code, out, err = launched("check", root, "-A", "annotation")
                @test code == 1 && occursin("error[shadowed-base]", out) && !occursin("annotation", out)
                @test occursin("building environment for Relaunched", err)
                code, out, err = launched("check", root, "-A", "shadowed-base")
                @test code == 0 && !occursin("building environment", err)
            end
            # Manifest pins TextWrap 0.3; Corset needs ArgParse 1, which needs TextWrap 1.
            mktempdir(@__DIR__) do root
                textwrap = "b718987f-49a8-5099-9789-dcd902bef87d"
                write(joinpath(root, "Project.toml"), "name = \"Pinned\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\n\n[deps]\nTextWrap = \"$textwrap\"\n\n[preferences.Corset]\nkind = \"library\"\n")
                write(joinpath(root, "Manifest.toml"), "manifest_format = \"2.0\"\n\n[[deps.TextWrap]]\ndeps = [\"Compat\", \"Test\"]\ngit-tree-sha1 = \"8355cc559e85469cd4dbe927c375f61d3750e002\"\nuuid = \"$textwrap\"\nversion = \"0.3.0\"\n")
                mkpath(joinpath(root, "src"))
                write(joinpath(root, "src", "Pinned.jl"), "\"\"\"Package with old Manifest.\"\"\"\nmodule Pinned\nend\n")
                code, _, err = launched("check", root)
                @test code == 2 && occursin("cannot build environment for Pinned that keeps every Manifest version", err) && occursin("TextWrap", err)
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

@testset "fix conflicts" begin
    span(first, last) = Corset.Facts.Span("f.jl", first, last, Corset.Facts.Precision.exact)
    fix(first, last) = Corset.Facts.Fix("t", [Corset.Facts.Edit(span(first, last), "x")], Corset.Facts.Tier.safe)
    finding(first, last) = Corset.Facts.Finding(:sample, :kind, Corset.Facts.Confidence.definite, "m", Corset.Facts.Label(span(first, last), "l"), Corset.Facts.Label[], "w", fix(first, last))
    edits = Corset.Fixes.applicable_edits([finding(1, 3), finding(2, 4), finding(5, 6)], "f.jl", Corset.Facts.Tier.safe)
    @test [edit.span.first_byte for edit in edits] == [1, 5]
end
