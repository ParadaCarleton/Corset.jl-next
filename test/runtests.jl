using Test: @testset

@testset "Corset" begin
    include("units.jl")
    include("registry.jl")
    include("ui.jl")
    include("properties.jl")
    include("cli.jl")
end
