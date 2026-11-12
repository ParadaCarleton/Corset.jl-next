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
const SARIF_SCHEMA = JSONSchema.Schema(JSON.parsefile(joinpath(@__DIR__, "fixtures", "sarif-schema-2.1.0.json")))

@testset "cli check" begin
    code, out, _ = corset("check", LIBRARY)
    @test code == 1 && occursin("error[approx-zero]", out) && endswith(out, "corset: 2 errors, 1 warning, 0 baselined\n")
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

@testset "cli formats" begin
    json = JSON.parse(corset("check", LIBRARY, "--format", "json", "--confidence", "possible")[2])
    @test json["version"] == 1 && json["baselined"] == 0 && isempty(json["stale"])
    @test [entry["rule"] for entry in json["diagnostics"]] == ["untyped-empty", "approx-zero", "approx-zero"]
    first_label = json["diagnostics"][1]["labels"][1]
    @test (first_label["file"], first_label["line"], first_label["column"], first_label["end_column"]) == ("a.jl", 2, 10, 12)
    sarif = JSON.parse(corset("check", LIBRARY, "--format", "sarif")[2])
    @test isnothing(JSONSchema.validate(SARIF_SCHEMA, sarif))
    @test [result["level"] for result in only(sarif["runs"])["results"]] == ["warning", "error", "error"]
end

@testset "cli fix, baseline, explain" begin
    directory = mktempdir(@__DIR__)
    write(joinpath(directory, "Project.toml"), "[deps]\n")
    write(joinpath(directory, "a.jl"), "f(x)::T where T = x\nreach(value) = value ≈ 0\n")
    sarif = JSON.parse(corset("check", directory, "--format", "sarif", "-A", "one-letter")[2])
    @test isnothing(JSONSchema.validate(SARIF_SCHEMA, sarif))
    @test any(!isempty(result["fixes"]) for result in only(sarif["runs"])["results"])
    code, _, err = corset("fix", directory, "--tier", "safe")
    @test occursin("applied 1 edits", err) && code == 1
    @test startswith(read(joinpath(directory, "a.jl"), String), "(f(x)::T) where T = x\n")
    @test occursin("wrote 1 findings", corset("baseline", directory, "-A", "one-letter")[3])
    @test first(corset("check", directory, "-A", "one-letter")) == 0
    write(joinpath(directory, "a.jl"), "x = 1\n")
    stale = corset("check", directory, "--format", "sarif", "-A", "one-letter")
    @test first(stale) == 1 && isnothing(JSONSchema.validate(SARIF_SCHEMA, JSON.parse(stale[2])))
    @test occursin("error[baseline]", corset("check", directory, "-A", "one-letter")[2])
    symlink(joinpath(directory, "missing.jl"), joinpath(directory, "broken.jl"))
    @test first(corset("check", directory)) == 101
    rm(directory; recursive = true)
    code, out, _ = corset("explain", "approx-zero")
    @test code == 0 && startswith(out, "approx-zero (correctness group, syntax stage, F10)")
    @test occursin("opt-outs that suppress nothing", corset("explain", "opt-out")[2])
    @test all(first(corset("explain", string(entry.name))) == 0 for entry in Corset.Rules.REGISTRY)
    @test occursin("Run `corset baseline`", corset("explain", "baseline")[2])
end

@testset "fix conflicts" begin
    span(first, last) = Corset.Facts.Span("f.jl", first, last, Corset.Facts.Precision.exact)
    fix(first, last) = Corset.Facts.Fix("t", [Corset.Facts.Edit(span(first, last), "x")], Corset.Facts.Tier.safe)
    finding(first, last) = Corset.Facts.Finding(:sample, :kind, Corset.Facts.Confidence.definite, "m", Corset.Facts.Label(span(first, last), "l"), Corset.Facts.Label[], "w", fix(first, last))
    edits = Corset.Fixes.applicable_edits([finding(1, 3), finding(2, 4), finding(5, 6)], "f.jl", Corset.Facts.Tier.safe)
    @test [edit.span.first_byte for edit in edits] == [1, 5]
end
