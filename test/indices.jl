# Fixtures of `one-based-range` run on offset arrays: code with index proof gives same result; code without throws.
using EvilArrays: EvilArray
using Test: @test, @testset, @test_throws

include(joinpath(@__DIR__, "ui", "one-based-range", "negative", "src", "OneBasedRangeNegative.jl"))
include(joinpath(@__DIR__, "ui", "one-based-range", "positive", "src", "OneBasedRangePositive.jl"))

const Negative = OneBasedRangeNegative
const Positive = OneBasedRangePositive

@testset "index proof holds on offset arrays" begin
    floats, ints, sorted, matrix = [3.0, -1.0, 2.0], [-2, 0, 5, 7], [1, 3, 3, 8], [1.0 2.0; 3.0 4.0]
    @test Negative.total(EvilArray(floats)) == Negative.total(floats)
    @test Negative.head(EvilArray(ints)) == -2
    @test Negative.tail(EvilArray(ints)) == 7
    evil = EvilArray(ints)
    @test parent(Negative.copy_into!(similar(evil), evil)) == ints
    @test parent(Negative.added!(copy(evil), evil)) == 2 .* ints
    @test_throws DimensionMismatch Negative.added!(EvilArray(ints), EvilArray(ints))
    @test_throws ArgumentError Negative.guarded_head(EvilArray(ints))
    @test parent(Negative.doubled(EvilArray(floats))) == 2 .* floats
    for target in -1:9
        offset = EvilArray(sorted)
        @test Negative.first_at_least(offset, target) - firstindex(offset) + 1 == Negative.first_at_least(sorted, target)
    end
    @test Negative.trace(EvilArray(matrix)) == Negative.trace(matrix) == 5.0
    @test all(iszero, Negative.zeroed!(EvilArray(copy(matrix))))
    @test Negative.first_positive(EvilArray(ints)) == 5
    @test Negative.largest(EvilArray(floats)) == 3.0
    offset = EvilArray(floats)
    @test Negative.simd_total(offset, similar(offset) .= offset) == Negative.simd_total(floats, floats)
    @test Negative.column_sums(EvilArray(matrix)) == Negative.column_sums(matrix) == [4.0, 6.0]
    @test sum(Negative.slice(evil, firstindex(evil), firstindex(evil) + 1)) == sum(Negative.slice(ints, 1, 2)) == -2
    @test Negative.capped(evil, typemax(Int)) == Negative.capped(ints, typemax(Int)) == 7
    @test Negative.scaled_head(EvilArray(floats)) == 7.0
    @test_throws ArgumentError Negative.guarded_total(evil)
    @test Negative.ends(evil) == Negative.ends(ints) == 5
end

@testset "code without index proof fails on offset arrays" begin
    floats, ints, matrix = [3.0, -1.0, 2.0], [-2, 0, 5, 7], [1.0 2.0; 3.0 4.0]
    @test_throws BoundsError Positive.total(EvilArray(floats))
    @test_throws BoundsError Positive.head(EvilArray(ints))
    @test_throws BoundsError Positive.doubled!(EvilArray(zeros(3)), floats)
    @test_throws BoundsError Positive.copy_into!(EvilArray(zeros(Int, 4)), ints)
    @test_throws BoundsError Positive.trace(EvilArray(matrix))
    @test_throws BoundsError Positive.picked(Positive.Picks([1, 2]), EvilArray(floats))
    @test_throws BoundsError Positive.first_at_least(EvilArray(ints), 3)
    evil = EvilArray(ints)
    @test_throws BoundsError Positive.parent_of(evil, lastindex(evil))
    @test_throws BoundsError Positive.prefix(evil, 2)
    @test_throws BoundsError Positive.offset_only(evil)
    @test_throws BoundsError Positive.aliased_offset(evil)
    @test_throws BoundsError Positive.both_heads(evil, evil)
    @test_throws BoundsError Positive.capped_by(evil, EvilArray(ints), typemax(Int))
    @test_throws BoundsError Positive.corner(EvilArray(matrix))
end

using Corset.Effects: Effects, offset_type, offset_signature, OffsetArray
using Corset.StandIns: ArrayStandIn, DenseStandIn

"""Struct whose bound rejects offset array."""
struct Dense{A <: DenseVector{Float64}}
    data::A
end

dense_sum(xs::DenseVector{Float64})::Float64 = sum(xs)
any_sum(xs::AbstractVector{Float64}, ys::DenseVector{Float64})::Float64 = sum(xs) + sum(ys)
same_sum(xs::T, ys::T) where {T <: AbstractVector{Float64}} = sum(xs) + sum(ys)
mixed_sum(xs::T, ys::T, zs::U) where {T <: AbstractVector{Float64}, U <: DenseVector{Float64}} = sum(xs) + sum(ys) + sum(zs)
chained_sum(xs::T, ys::T, zs::S) where {T <: AbstractVector{Float64}, S <: T} = sum(xs) + sum(ys) + sum(zs)

@testset "offset stand-in replaces array stand-in where bounds allow" begin
    vector = ArrayStandIn{Float64, 1}
    @test offset_type(vector) == OffsetArray{Float64, 1, vector}
    @test offset_type(Union{Nothing, vector}) == Union{Nothing, OffsetArray{Float64, 1, vector}}
    @test offset_type(ArrayStandIn{<:Any, 1}) == (OffsetArray{T, 1, ArrayStandIn{T, 1}} where {T})
    @test offset_type(Vector{vector}) == Vector{OffsetArray{Float64, 1, vector}}
    @test offset_type(Dense{DenseStandIn{Float64, 1}}) == Dense{DenseStandIn{Float64, 1}}
    @test offset_type(Int) == Int
    dense, plain = DenseStandIn{Float64, 1}, ArrayStandIn{Float64, 1}
    @test isnothing(offset_signature(only(methods(dense_sum)), Tuple{typeof(dense_sum), dense}))
    @test offset_signature(only(methods(any_sum)), Tuple{typeof(any_sum), plain, dense}) == Tuple{typeof(any_sum), OffsetArray{Float64, 1, plain}, dense}
    # Lowered code keeps indexing that one-based stand-in drops.
    @test Effects.lowered_indexing(only(methods(Positive.offset_only))) && !Effects.lowered_indexing(only(methods(dense_sum)))
    @test Effects.lowered_indexing(only(methods(Positive.aliased_offset)))
    # Arguments that share type variable change together.
    offset = OffsetArray{Float64, 1, plain}
    @test offset_signature(only(methods(same_sum)), Tuple{typeof(same_sum), plain, plain}) == Tuple{typeof(same_sum), offset, offset}
    # Group of shared type changes without argument that its own bound rejects.
    @test offset_signature(only(methods(mixed_sum)), Tuple{typeof(mixed_sum), plain, plain, dense}) == Tuple{typeof(mixed_sum), offset, offset, dense}
    # Variable bounded by shared variable joins its group.
    @test offset_signature(only(methods(chained_sum)), Tuple{typeof(chained_sum), plain, plain, plain}) == Tuple{typeof(chained_sum), offset, offset, offset}
end

@testset "dimension count has no upper limit" begin
    @test Effects.dimension_count(Array{Float64, 9}) == 9
    @test Effects.dimension_count(OffsetArray{Float64, 12, ArrayStandIn{Float64, 12}}) == 12
    @test Effects.dimension_count(Vector) == 1
    @test Effects.dimension_count(Array{Int, 0}) == 0
    @test Effects.dimension_count(Union{Vector{Int}, SubArray{Int, 1}}) == 1
    @test Effects.dimension_count(Union{Vector{T}, Matrix{T}} where {T}) === nothing
    @test Effects.dimension_count(Array{Float64}) === nothing
    @test Effects.dimension_count(Union{Nothing, Vector{Int}}) === nothing
    @test Effects.dimension_count(Union{}) === nothing
end
