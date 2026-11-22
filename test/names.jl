using Test: @test, @testset
using Random: AbstractRNG
using Corset.Facts: Callee, Place, Root, Step, callee_name, callee_methods, place_text, root_global, rng_positions

"""Provide typed arguments for facts helper tests."""
function named_arguments(generator::AbstractRNG, item::Any)::Nothing
    return nothing
end

"""Provide a bounded RNG argument for facts helper tests."""
function bounded_argument(generator::T)::Nothing where {T <: AbstractRNG}
    return nothing
end

"""Provide an untyped argument for facts helper tests."""
function unconstrained_argument(item::Any)::Nothing
    return nothing
end

@testset "name facts helpers" begin
    method = only(methods(named_arguments))
    @test rng_positions(method) == [1]
    @test rng_positions(only(methods(bounded_argument))) == [1]
    @test rng_positions(only(methods(unconstrained_argument))) == Int[]
    @test callee_name(Callee.Methods([method])) == "named_arguments"
    @test callee_name(Callee.Methods(Method[])) === nothing
    @test callee_name(Callee.Open()) === nothing
    @test callee_name(Callee.Builtin(Core.getfield)) == "getfield"
    @test callee_methods(Callee.Methods([method])) == [method]
    @test callee_methods(Callee.Open()) === nothing
    argument = Place.At(Root.Parameter(2), Step.Type[Step.Field(:state), Step.Position(1), Step.Element()])
    @test place_text(method, argument) == "generator.state[1][…]"
    @test root_global(argument) === nothing
    binding = GlobalRef(@__MODULE__, :named_arguments)
    global_place = Place.Deep(Root.Global(binding))
    @test root_global(global_place) == binding
    @test endswith(place_text(method, global_place), ".named_arguments or below")
end
