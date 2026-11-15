using Test: @test, @testset

@testset "Corset" begin
    include("units.jl")
    include("standins.jl")
    include("signatures.jl")
    include("inference.jl")
    include("registry.jl")
    include("ui.jl")
    include("properties.jl")
    include("cli.jl")
    include("cache.jl")
    include("invalidation.jl")
    # Coverage instrumentation slows code many times, so speed tests run in process without it.
    if Base.JLOptions().code_coverage == 0
        include("perf.jl")
    else
        perf = `$(Base.julia_cmd()) --code-coverage=none --project=$(Base.active_project()) $(joinpath(@__DIR__, "perf.jl"))`
        @test success(pipeline(perf; stdout, stderr))
    end
end
