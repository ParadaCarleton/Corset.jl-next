# Command-line tests: exit codes, output formats, fix, baseline and explain.

using Corset: Corset
using JSON: JSON
using JSONSchema: JSONSchema
using Test: @test, @testset

"""Exit code, standard output and standard error of `corset args...`."""
function corset(args::String...)::Tuple{Int, String, String}
    out, err = IOBuffer(), IOBuffer()
    code = Corset.CLI.execute(String[args...], out, err)
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
    @test occursin("no level, opt-out or baseline hides", corset("explain", "load-error")[2])
end

@testset "fix conflicts" begin
    span(first, last) = Corset.Facts.Span("f.jl", first, last, Corset.Facts.Precision.exact)
    fix(first, last) = Corset.Facts.Fix("t", [Corset.Facts.Edit(span(first, last), "x")], Corset.Facts.Tier.safe)
    finding(first, last) = Corset.Facts.Finding(:sample, :kind, Corset.Facts.Confidence.definite, "m", Corset.Facts.Label(span(first, last), "l"), Corset.Facts.Label[], "w", fix(first, last))
    edits = Corset.Fixes.applicable_edits([finding(1, 3), finding(2, 4), finding(5, 6)], "f.jl", Corset.Facts.Tier.safe)
    @test [edit.span.first_byte for edit in edits] == [1, 5]
end
