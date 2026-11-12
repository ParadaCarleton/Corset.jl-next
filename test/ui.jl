# UI snapshot tests, as in Clippy: test/ui/<check>/<case>.jl, rendered output in <case>.out,
# fixed source in <case>.fixed.jl. Set CORSET_BLESS=1 to rewrite snapshots.
# Each case starts with `# runic: off`: formatter must not normalize syntax cases test.

using Corset: Corset
using Corset.Facts: FactSet, Tier
using Test: @test, @testset

const UI = joinpath(@__DIR__, "ui")
const BLESS = get(ENV, "CORSET_BLESS", "") == "1"

"""Compare `actual` with snapshot `path`; write it when blessing. Missing snapshot means empty expected text."""
function snapshot(path::String, actual::String)::Bool
    BLESS && (isempty(actual) ? (isfile(path) && rm(path)) : write(path, actual))
    return actual == (isfile(path) ? read(path, String) : "")
end

"""Rendered findings and fixed source for `case` of check `name`."""
function run_case(name::Symbol, case::String)::Tuple{String, String}
    text = read(case, String)
    file = Corset.Syntax.parse_file(basename(case), text)
    entry = Corset.Checks.entry(name)
    findings = Corset.Engine.run_checks(FactSet([file]), [entry])
    rendered = sprint() do io
        for finding in findings
            Corset.Render.render(io, finding, entry.group, text)
            println(io)
        end
    end
    fixed = Corset.Fixes.apply_edits(text, Corset.Fixes.applicable_edits(findings, file.path, Tier.breaking))
    return rendered, fixed == text ? "" : fixed
end

@testset "UI $(check)" for check in sort!(readdir(UI))
    directory = joinpath(UI, check)
    cases = sort!(filter(name -> endswith(name, ".jl") && !endswith(name, ".fixed.jl"), readdir(directory)))
    @test "positive.jl" in cases
    @test "negative.jl" in cases
    for case in cases
        @test startswith(read(joinpath(directory, case), String), "# runic: off\n")
        rendered, fixed = run_case(Symbol(check), joinpath(directory, case))
        stem = joinpath(directory, chopsuffix(case, ".jl"))
        @test snapshot(stem * ".out", rendered)
        @test snapshot(stem * ".fixed.jl", fixed)
        case == "negative.jl" && @test isempty(rendered)
        case == "positive.jl" && @test !isempty(rendered)
    end
end

@testset "every check has UI tests" begin
    @test sort!([string(entry.name) for entry in Corset.Checks.REGISTRY]) == sort!(readdir(UI))
end
