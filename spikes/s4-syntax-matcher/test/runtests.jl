using Test
include(joinpath(@__DIR__, "..", "src", "S4Matcher.jl"))
include(joinpath(@__DIR__, "..", "src", "rules.jl"))

"""Footgun ids found in `src` by `rules`."""
found(src::String, rules::Vector{Rule} = footgun_rules())::Vector{Int} = [f.footgun for f in run_rules(rules, "t.jl", src, parse_file(src))]

@testset "positive" begin
    @test found("y = x ≈ 0") == [10]
    @test found("isapprox(0.0, x)") == [10]
    @test found("!(x ≈ 0f0)") == [10]
    @test found("a = []") == [21]
    @test found("d = Dict()") == [21]
    @test found("fill(zeros(3), n)") == [35]
    @test found("fill(Vector{Int}(undef, 2), n, m)") == [35]
    @test found("fill([], n)") == [35, 21]
    @test found("for i in 1:length(a)\nend") == [36]
    @test found("1:(length(a))") == [36]
    @test found("bufs[threadid()] += 1") == [68]
    @test found("bufs[Threads.threadid()]") == [68]
    @test found("for i in 1:length(a)\n s += a[i]\nend", lintapp_shaped_rules()) == [36]
    @test found("for i = 1:length(a)\n s += a[i]\nend", lintapp_shaped_rules()) == [36]
end

@testset "negative" begin
    @test isempty(found("isapprox(x, 0; atol = 1e-8)"))
    @test isempty(found("x ≈ 1"))
    @test isempty(found("x == 0"))
    @test isempty(found("Int[]"))
    @test isempty(found("Dict(1 => 2)"))
    @test isempty(found("fill(0.0, n)"))
    @test isempty(found("fill(f(x), n)"))
    @test isempty(found("2:length(a)"))
    @test isempty(found("eachindex(a)"))
    @test isempty(found("bufs[i]"))
    @test isempty(found("for i in 1:length(a)\n s += b[i]\nend", lintapp_shaped_rules()))
    @test isempty(found("# x ≈ 0\n\"x ≈ 0\""))
end

@testset "matcher" begin
    @test_throws ArgumentError compile_pattern("_x")
    @test_throws Exception compile_pattern("f(")
    p = compile_pattern("f(_x, _x)")
    @test !isnothing(match_pattern(p, "f(a + 1, a+1)", parse_file("f(a + 1, a+1)") |> t -> S4Matcher.significant_children(t)[1]))
    @test isnothing(match_pattern(p, "f(a, b)", parse_file("f(a, b)") |> t -> S4Matcher.significant_children(t)[1]))
    q = compile_pattern("g(_xs..., 1)")
    src = "g(a, b, 1)"
    b = match_pattern(q, src, S4Matcher.significant_children(parse_file(src))[1])
    @test length(sequence(b, :_xs)) == 2
end

@testset "ancestors" begin
    @test isempty(found("function f(r, a)\n require_one_based_indexing(r, a)\n for i = 1:size(a, 2)\n end\nend"))
    @test found("function f(r, a)\n require_one_based_indexing(r)\n for i = 1:size(a, 2)\n end\nend") == [36]
    @test isempty(found("g(a) = (Base.require_one_based_indexing(a); [a[i] for i in 1:length(a)])"))
end

@testset "generator" begin
    @test found("T(n[i] => v[i] for i in 1:length(n))", lintapp_shaped_rules()) == [36]
end
