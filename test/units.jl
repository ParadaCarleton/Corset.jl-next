# Unit tests for skeleton pieces that UI snapshots do not reach.

using Corset: Corset
using Corset.Facts: Facts, Span, Label, Edit, Fix, Finding, Precision, Tier, Confidence, Group, Rule, @pattern
using Test: @test, @testset, @test_throws

"""Finding in file `name` with primary span `bytes`, causes `causes` and fix `fix`."""
function sample_finding(bytes::UnitRange{Int}; precision = Precision.exact, causes = Label[], fix = nothing)::Finding
    return Finding(
        :sample, :kind, Confidence.definite, "headline", Label(Span("f.jl", first(bytes), last(bytes), precision), "primary"),
        causes, "reason", fix,
    )
end

@testset "fixes" begin
    text = "abc def"
    edit(first, last, replacement) = Edit(Span("f.jl", first, last, Precision.exact), replacement)
    @test Corset.Fixes.apply_edits(text, [edit(5, 7, "xyz"), edit(1, 1, "A")]) == "Abc xyz"
    @test_throws ArgumentError Corset.Fixes.apply_edits(text, [edit(1, 3, "x"), edit(3, 4, "y")])
    findings = [
        sample_finding(1:1; fix = Fix("t", [edit(1, 1, "A")], Tier.safe)),
        sample_finding(5:7; fix = Fix("t", [edit(5, 7, "xyz")], Tier.breaking)),
        sample_finding(2:2; fix = Fix("t", Edit[], Tier.manual)),
        sample_finding(3:3),
    ]
    @test length(Corset.Fixes.applicable_edits(findings, "f.jl", Tier.safe)) == 1
    @test length(Corset.Fixes.applicable_edits(findings, "f.jl", Tier.manual)) == 2
    @test isempty(Corset.Fixes.applicable_edits(findings, "other.jl", Tier.manual))
end

@testset "render" begin
    text = "a = 1\nb = 2\nc = 3\nd = 4\ne = 5\n"
    render(finding) = sprint(io -> Corset.Render.render(io, finding, Group.readability, text))
    adjacent = render(sample_finding(13:17; causes = [Label(Span("f.jl", 1, 5, Precision.exact), "cause")]))
    @test occursin("2 | b = 2", adjacent)
    gap = render(sample_finding(25:29; causes = [Label(Span("f.jl", 1, 5, Precision.exact), "cause")]))
    @test occursin("...", gap)
    whole_line = render(sample_finding(15:15; precision = Precision.line))
    @test occursin("  | ^^^^^ primary", whole_line)
    multi_line = render(sample_finding(1:9))
    @test occursin("  | ^^^^^ primary", multi_line)
    @test Corset.Render.line_text("x\r\n", [1, 4], 1) == "x"
    tabbed = "\ty = 1\n"
    @test occursin("1 |     y = 1\n  |     ^ primary", sprint(io -> Corset.Render.render(io, sample_finding(2:2), Group.readability, tabbed)))
end

@testset "facts" begin
    @test isnothing(Rule(@pattern {x}).roots)
    @test isnothing(Rule(@pattern ~or(f({x}), {y})).roots)
    mixed = Rule(@pattern ~or(f({x}), g({x}), [], {a}.b({x}), h({x})))
    @test mixed.roots[Corset.Syntax.JS.K"call"] === nothing
    @test mixed.roots[Corset.Syntax.JS.K"vect"] === nothing
    @test Rule(@pattern ~or(f({x}), g({x}))).roots[Corset.Syntax.JS.K"call"] == Set(["f", "g"])
    file = Corset.Syntax.parse_file("f.jl", "g(1)\n")
    @test length(Facts.matches(file, Rule(@pattern {x}))) > 1
    @test Facts.identifier_name(Facts.nodes_of_kind(file, Corset.Syntax.JS.K"Integer")[1]) === nothing
    @test isempty(Facts.children_of(Facts.nodes_of_kind(file, Corset.Syntax.JS.K"Integer")[1]))
end

@testset "engine" begin
    directory = mktempdir(@__DIR__)
    write(joinpath(directory, "a.jl"), "x ≈ 0\n")
    write(joinpath(directory, "notes.txt"), "x ≈ 0\n")
    @test Corset.Engine.julia_files(directory) == [joinpath(directory, "a.jl")]
    @test Corset.Engine.julia_files(joinpath(directory, "a.jl")) == [joinpath(directory, "a.jl")]
    @test_throws ArgumentError Corset.Engine.julia_files(joinpath(directory, "missing"))
    @test [finding.check for finding in Corset.check(directory)] == [Symbol("approx-zero")]
    @test_throws ArgumentError Corset.Checks.entry(:no_such_check)
    rm(directory; recursive = true)
end
