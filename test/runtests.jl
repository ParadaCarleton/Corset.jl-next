using Test: @test, @testset

"""Include test `file` in own module: names of one file, imports included, never clash with names of other file."""
function isolated(file::String)::Any
    holder = Core.eval(Main, Expr(:module, true, Symbol("Test_", splitext(file)[1]), Expr(:block)))
    return Base.include(holder, joinpath(@__DIR__, file))
end

@testset "Corset" begin
    isolated("units.jl")
    isolated("standins.jl")
    isolated("signatures.jl")
    isolated("inference.jl")
    isolated("widening.jl")
    isolated("hard_arrays.jl")
    isolated("guesses.jl")
    isolated("narrowing.jl")
    isolated("boxes.jl")
    isolated("effects.jl")
    isolated("summary_cache.jl")
    isolated("registry.jl")
    isolated("ui.jl")
    isolated("properties.jl")
    isolated("cli.jl")
    isolated("cache.jl")
    isolated("invalidation.jl")
    # Coverage instrumentation slows code many times, so speed tests run in process without it.
    if Base.JLOptions().code_coverage == 0
        isolated("perf.jl")
    else
        perf = `$(Base.julia_cmd()) --code-coverage=none --project=$(Base.active_project()) $(joinpath(@__DIR__, "perf.jl"))`
        @test success(pipeline(perf; stdout, stderr))
    end
end
