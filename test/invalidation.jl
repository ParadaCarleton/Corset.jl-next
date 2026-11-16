# Invalidation: methods that target packages add must leave Corset compiled code valid, or relaunched process infers it again.

using Test: @test, @testset

@testset "invalidation" begin
    directory = joinpath(@__DIR__, "fixtures", "invalidation")
    probe = `$(Base.julia_cmd()) --code-coverage=none --startup-file=no --project=$(Base.active_project()) $(joinpath(directory, "probe.jl")) $(joinpath(directory, "Invalidator.jl"))`
    lines = readlines(pipeline(probe; stderr))
    # Fixture that invalidates nothing would prove nothing.
    @test parse(Int, last(lines)) > 0
    @test isempty(lines[1:(end - 1)])
end
