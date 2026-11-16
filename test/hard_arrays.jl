using Test: @test, @testset
using Corset: Corset
using Corset.Facts: Exit
using Corset.StandIns: FloatStandIn, ArrayStandIn, DenseStandIn, Templated
using Corset.HardArrays: changes!, holds_array

"""Methods `HardArrays` scans: hard-coded arrays that drop caller's array type, and code that keeps it."""
module HardArrayCases
    returned(xs) = zeros(length(xs))
    typed(xs) = Vector{Float64}(undef, length(xs))
    similar_type(xs) = similar(Vector{Float64}, length(xs))
    function stored!(cache::Vector{Any}, xs)
        cache[1] = ones(length(xs))
        return nothing
    end
    function buffered(xs)
        buffer = fill(0.0, length(xs))
        buffer .= xs
        return sum(buffer)
    end
    second(xs, ys) = zeros(length(ys))
    branched(xs) = xs isa Vector ? xs : zeros(length(xs))
    # No finding: built from input, never meets input, store converts, callee takes `Array` only, no input array.
    templated(xs) = similar(xs, Float64, length(xs))
    converted(xs) = Vector{Float64}(xs)
    paired(xs) = sum(zeros(length(xs)) .+ ones(length(xs)))
    function concrete!(cache::Vector{Vector{Float64}}, xs)
        cache[1] = zeros(length(xs))
        return nothing
    end
    array_length(a::Array) = length(a)
    measured(xs) = array_length(zeros(length(xs)))
    # Second construction stays when first makes callee throw.
    measured_pair(xs) = (array_length(zeros(length(xs))), ones(length(xs)))
    # Tuple builtin carries construction and input to call.
    measure_pair(pair) = length(pair[1]) + length(pair[2])
    tupled(xs) = measure_pair((xs, zeros(length(xs))))
    # Builtins only move values: tuple, then `getfield` returns input, so nothing mixes.
    picked(xs) = getfield((xs, zeros(length(xs))), 1)
    grid(n) = zeros(n, n)
end

"""Changes `HardArrays` finds in `f` on argument types `arguments`, as (callee, template slot, exit), and type branch."""
function scan(f::Function, arguments::Type...)::Tuple{Vector{Tuple{Any, Int, Exit.T}}, Bool}
    instance, code, _, _ = something(Corset.Inference.infer(only(methods(f)), Tuple{typeof(f), arguments...}))
    found, branch = changes!(Any[], instance, code)
    return [(change.construction.callee, change.construction.template, change.exit) for change in found], branch
end

const FV, DV = ArrayStandIn{FloatStandIn, 1}, DenseStandIn{FloatStandIn, 1}

@testset "hard arrays" begin
    cases = HardArrayCases
    @testset "escape" begin
        @test scan(cases.returned, FV) == ([(zeros, 2, Exit.returned)], false)
        @test scan(cases.returned, DV) == ([(zeros, 2, Exit.returned)], false)
        @test scan(cases.typed, FV) == ([(Vector{Float64}, 2, Exit.returned)], false)
        @test scan(cases.similar_type, FV) == ([(similar, 2, Exit.returned)], false)
        @test scan(cases.stored!, Vector{Any}, FV) == ([(ones, 3, Exit.stored)], false)
        # Template is array argument dimensions read.
        @test scan(cases.second, FV, FV) == ([(zeros, 3, Exit.returned)], false)
        @test scan(cases.branched, FV) == ([(zeros, 2, Exit.returned)], true)
    end
    @testset "meeting" begin
        @test scan(cases.buffered, FV) == ([(fill, 2, Exit.intermediate)], false)
        @test scan(cases.tupled, FV) == ([(zeros, 2, Exit.intermediate)], false)
    end
    @testset "no finding" begin
        @test isempty(first(scan(cases.templated, FV)))
        @test isempty(first(scan(cases.converted, FV)))
        # Hard-coded arrays that meet only each other mix no caller array.
        @test isempty(first(scan(cases.paired, FV)))
        @test isempty(first(scan(cases.concrete!, Vector{Vector{Float64}}, FV)))
        @test isempty(first(scan(cases.measured, FV)))
        @test scan(cases.measured_pair, FV) == ([(ones, 2, Exit.returned)], false)
        @test isempty(first(scan(cases.grid, Int)))
        @test isempty(first(scan(cases.picked, FV)))
        @test isempty(first(scan(cases.returned, Vector{Float64})))
    end
    @testset "stand-in" begin
        @test Templated{ArrayStandIn}(zeros)(3) isa ArrayStandIn{Float64, 1}
        @test Templated{DenseStandIn}(Vector{Int})(undef, 2) isa DenseStandIn{Int, 1}
        @test holds_array(Base.Broadcast.Broadcasted{Nothing, Nothing, typeof(+), Tuple{FV, Int}})
        @test holds_array(Union{Nothing, FV})
        @test !holds_array(Vector{Float64})
    end
end
