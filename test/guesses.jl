using Test: @test, @testset, @test_throws
using Corset: Corset
using Corset.Guesses: annotation_text, family_text, array_shape, array_dimensions
using Corset.StandIns: FloatStandIn, IntStandIn, ArrayStandIn

"""Array struct that leaves count parameter free, as `Interpolations.GriddedInterpolation` does."""
struct OddArray{T, N} <: AbstractArray{T, N} end

"""Scope guesses name types in: abstract type with one struct, and struct without abstract parent."""
module GuessScope
    abstract type Shape end
    struct Circle <: Shape end
    struct Loose end
end
"""Scope with own `Function` struct: it shadows Base family name, so guess text names other type there."""
module Shadowing
    struct Function end
end
"""Struct outside `GuessScope`: its name is unbound there."""
struct Hidden end

@testset "array count parameter" begin
    # `ndims` threw on count `Any` (Interpolations corpus run).
    @test array_shape(OddArray{Any, Any}) == (nothing, Any) && array_shape(OddArray{Int, 2}) == (2, Int)
    @test array_shape(OddArray{Int, N} where {N}) == (nothing, Any) && array_shape(SubArray{T, 2} where {T}) == (2, Any)
    @test array_shape(Union{Vector{Int}, Matrix{Int}}) == (nothing, Any) && family_text(OddArray{Any, Any}, GuessScope) == "AbstractArray"
    @test_throws ArgumentError array_dimensions(Int)
end

@testset "annotation guesses" begin
    scope = GuessScope
    guess(types...) = annotation_text(Any[types...], scope)
    @testset "families" begin
        @test guess(Int, Int32) == "Integer"
        @test guess(Int, Float64) == "Real"
        @test guess(Bool) == "Bool"
        @test guess(Bool, Int) == "Integer"
        @test guess(FloatStandIn, IntStandIn) == "Real"
        @test guess(Vector{Int}, ArrayStandIn{FloatStandIn, 1}) == "AbstractVector{<:Real}"
        @test guess(Matrix{Float64}) == "AbstractMatrix{<:Real}"
        @test guess(Array{Float64, 3}) == "AbstractArray{<:Real, 3}"
        @test guess(Vector{Any}) == "AbstractVector"
        @test guess(Array{Any, 3}) == "AbstractArray{<:Any, 3}"
        @test guess(Vector{String}) == "AbstractVector{<:AbstractString}"
        # Open stand-in elements and counts: element bound names family; open count names none.
        @test guess(ArrayStandIn{<:Any, 1}) == "AbstractVector" && guess(ArrayStandIn) == "AbstractArray"
        @test guess(ArrayStandIn{<:AbstractString, 3}) == "AbstractArray{<:AbstractString, 3}"
        @test guess(ArrayStandIn{FloatStandIn}) == "AbstractArray{<:Real}" && guess(Vector{<:Real}) == "AbstractVector{<:Real}"
        @test guess(SubArray{Float64, 1, Matrix{Float64}, Tuple{Base.Slice{Base.OneTo{Int}}, Int}, true}) == "AbstractVector{<:Real}"
        # View of open stand-in: family of other type than `Array` gives count when every member shares it.
        @test guess(SubArray{T, 1, ArrayStandIn{T, 2}, Tuple{Base.Slice{Base.OneTo{Int}}, Int}, true} where {T}) == "AbstractVector"
        @test guess(SubArray) == "AbstractArray"
        @test guess(String, SubString{String}) == "AbstractString"
        @test guess(ComplexF64) == "Number"
        @test guess(typeof(sin)) == "Function"
        @test guess(GuessScope.Circle) == "Shape"
        @test guess(GuessScope.Loose) == "Loose"
    end
    @testset "unions" begin
        @test guess(Union{Int, Nothing}) == "Union{Integer, Nothing}"
        @test guess(Missing, Float64, String) == "Union{Real, AbstractString, Missing}"
        # Four families are too many to name.
        @test isnothing(guess(Float64, Missing, String, Symbol))
    end
    @testset "no guess" begin
        @test isnothing(guess(Any))
        @test isnothing(guess(Hidden))
        @test isnothing(guess(Vector{Hidden}))
        @test isnothing(annotation_text(Any[], scope))
        @test isnothing(family_text(Ref{<:Real}, scope)) && isnothing(guess(Vector{<:Hidden}))
        @test isnothing(annotation_text(Any[typeof(sin)], Shadowing))
    end
    @testset "evidence" begin
        # Message lists first three distinct types; stand-ins print as models.
        @test Corset.Guesses.evidence(Any[Int8, Int16, Int8, Int32, Int64], Main) == ["Int8", "Int16", "Int32"]
        @test Corset.Guesses.evidence(Any[FloatStandIn, GuessScope.Circle], GuessScope) == ["Float32", "Circle"]
        # Closure types of pullbacks once filled whole message line.
        @test Corset.Guesses.evidence(Any[Tuple{Vector{Float64}, Dict{String, Vector{Int}}}, Union{Int, Nothing}], Main) == ["Tuple{…}", "Union{Nothing, Int64}"]
    end
    @testset "named type" begin
        named(text) = Corset.Guesses.named_type(text, @__MODULE__)
        @test named("Vector{Int}") == Vector{Int}
        # Unknown name, bad parameter, and non-type value give no type.
        @test all(isnothing, named.(["NoSuchType", "Union{1}", "1"]))
        @test_throws ErrorException named("error(\"other\")")
    end
    @testset "defaults" begin
        file = Corset.Syntax.parse_file("defaults.jl", "f(a, b = 1, c = 2.0, d = nothing, e = \"s\", g = zero(Int), _, h::Int = 1) = a", Corset.Facts.Role.package)
        parts = something(Corset.Facts.signature(first(Corset.Facts.forms(file, "function"))))
        @test [Corset.Guesses.default_type(file, part) for part in parts.arguments] == [nothing, Int, Float64, Nothing, String, nothing, nothing, Int]
        names = [Corset.Guesses.argument_name(part) for part in parts.arguments]
        @test [isnothing(name) ? nothing : Corset.Facts.source(file, name) for name in names] == ["a", "b", "c", "d", "e", "g", nothing, nothing]
    end
end
