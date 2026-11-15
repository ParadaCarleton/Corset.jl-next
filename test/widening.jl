using Test: @test, @testset
using Corset: Corset
using Corset.Facts: Weak, Exit, Disruption, Span, Precision, Confidence
using Corset.StandIns: FloatStandIn, IntStandIn, ArrayStandIn
using Corset.Widening: changes!, swapped, replacement, weak, call_result!, number_stand_in, index_only, ROUNDS

"""Methods `Widening` scans: weak values that change input type, and code that keeps it."""
module WideningCases
    using Corset.StandIns: FloatStandIn
    const HALF = 0.5
    const COEFFICIENTS = (1.0, 2.0)
    global untyped_total = 0.0
    global typed_total::Float64 = 0.0
    takes_int(n::Int) = n
    mutable struct Holder
        loose::Real
        tight::Float32
    end
    """Type whose parameter bound admits float stand-in but not `Float64`."""
    struct Picky{T <: Union{Float32, FloatStandIn}}
        value::T
    end
    picked(p::Picky, y) = p.value + y
    scaled(x) = x * 0.5
    doubled(x) = 2x
    halved(x) = x / 2
    named(x) = Float64(x) + x
    narrowed(x) = Float32(x)
    renamed(n) = Int(n)
    converted(x) = convert(Float64, x)
    broadcast_named(xs) = Float64.(xs)
    constant(x) = HALF * x
    precise(x) = BigFloat(x) * x
    grid(x) = [x 0.5; 1.0 2.0]
    fused(x) = muladd(x, 3.0, 2)
    masked(n) = (UInt64(n) - 1) & 63
    unsigned(n) = convert(UInt64, n)
    digit(n) = UInt8(n % 10)
    halfwidth(x) = Float16(x) * x
    function keyed!(table, x)
        table[:a] = x * 2.0
        return nothing
    end
    function local_store(x)
        buffer = Vector{Real}(undef, 1)
        buffer[1] = x * 2.0
        return Float32(x)
    end
    loose_global(x) = untyped_total * x
    rooted(x) = sqrt(2) * x
    circled(x) = 2π * x
    poly(x) = @evalpoly(x, 1.0, 2.0, 3.0)
    tupled(x) = evalpoly(x, COEFFICIENTS)
    chained(x) = x * 2.0 + 1.0
    horner(x) = 1.0 + x * (2.0 + x * (3.0 + x * (4.0 + x * 5.0)))
    function summed(xs)
        s = 0
        for v in xs
            s += v
        end
        return s
    end
    inner(x) = Float32(x * 0.5)
    following(xs, i) = xs[i + 1]
    window(xs, i) = sum(xs[1:2i])
    function looped(xs, i)
        t = zero(eltype(xs))
        for j in 1:2i
            t += xs[j]
        end
        return t
    end
    function counted(xs, i)
        k = i + 1
        k > length(xs) && return zero(eltype(xs))
        return xs[k]
    end
    range_out(i) = 1:2i
    filled(n) = fill(0, n)
    kinded(n) = n + 0.5
    huge(n) = n + 10^12
    squared(x) = x^2
    picky(x) = picked(Picky(x), 0.5)
    function stored!(out, x)
        out[1] = x * 2.0
        return nothing
    end
    function pushed!(out, x)
        push!(out, x * 2.0)
        return out
    end
    function held!(holder, x)
        holder.loose = x * 2.0
        holder.tight = x * 2.0
        return nothing
    end
    function global_store(x)
        global untyped_total = x * 2.0
        global typed_total = x * 2.0
        return nothing
    end
    branched(x) = x isa Float32 ? x : x * 0.5
    compared(x) = typeof(x) == Float64 ? x : x * 0.5
    broke(n) = (takes_int(2n), 3n)
    broke_all(n) = takes_int(2n)
    @inline static(x::T) where {T} = x * T(0.5) + 0.5
end

"""Changes `Widening` finds in `f` on argument types `arguments`, as (kind, value, exit, found, expected), and type branch."""
function scan(f::Function, arguments::Type...)::Tuple{Vector{Tuple{Weak.T, Any, Exit.T, Type, Type}}, Bool}
    signature = Tuple{typeof(f), arguments...}
    instance, code, _, _ = something(Corset.Inference.infer(only(methods(f)), signature))
    found, branch = changes!(Any[], instance, code)
    return [(change.origin.kind, change.origin.value, change.exit, change.found, change.expected) for change in found], branch
end

"""Weak values `scan` reports, without types."""
reported(f::Function, arguments::Type...)::Vector{Tuple{Weak.T, Any, Exit.T}} = [change[1:3] for change in first(scan(f, arguments...))]

const F, I, FV, IV = FloatStandIn, IntStandIn, ArrayStandIn{FloatStandIn, 1}, ArrayStandIn{IntStandIn, 1}

@testset "widening" begin
    cases = WideningCases
    @testset "weak values that escape" begin
        @test scan(cases.scaled, F) == ([(Weak.literal, 0.5, Exit.returned, Float64, F)], false)
        @test reported(cases.doubled, I) == [(Weak.literal, 2, Exit.returned)]
        @test reported(cases.named, F) == [(Weak.name, Float64, Exit.returned)]
        @test reported(cases.renamed, I) == [(Weak.name, Int64, Exit.returned)]
        @test reported(cases.converted, F) == [(Weak.name, Float64, Exit.returned)]
        @test reported(cases.broadcast_named, FV) == [(Weak.name, Float64, Exit.returned)]
        @test reported(cases.constant, F) == [(Weak.constant, 0.5, Exit.returned)]
        @test reported(cases.rooted, F) == [(Weak.constant, sqrt(2), Exit.returned)]
        @test reported(cases.circled, F) == [(Weak.constant, 2π, Exit.returned)]
        @test reported(cases.poly, F) == [(Weak.literal, (1.0, 2.0, 3.0), Exit.returned)]
        @test reported(cases.tupled, F) == [(Weak.constant, (1.0, 2.0), Exit.returned)]
        # Second literal meets input only once first converts.
        @test reported(cases.chained, F) == [(Weak.literal, 2.0, Exit.returned), (Weak.literal, 1.0, Exit.returned)]
        @test length(reported(cases.horner, F)) == 5
        @test scan(cases.summed, FV) == ([(Weak.variable, 0, Exit.returned, Union{Int64, F}, F)], false)
        @test reported(cases.summed, IV) == [(Weak.variable, 0, Exit.returned)]
        @test reported(cases.range_out, I) == [(Weak.literal, 2, Exit.returned), (Weak.literal, 1, Exit.returned)]
        @test reported(cases.static, F) == [(Weak.literal, 0.5, Exit.returned)]
        # Row lengths of matrix literal cannot convert; elements still do.
        @test reported(cases.grid, F) == [(Weak.literal, 0.5, Exit.returned), (Weak.literal, 1.0, Exit.returned), (Weak.literal, 2.0, Exit.returned)]
        # Integer addend takes input type once other weak value converts.
        @test reported(cases.fused, F) == [(Weak.literal, 3.0, Exit.returned)]
    end
    @testset "stores" begin
        @test reported(cases.stored!, Vector{Real}, F) == [(Weak.literal, 2.0, Exit.stored)]
        @test reported(cases.stored!, Vector{Float32}, F) == [(Weak.literal, 2.0, Exit.intermediate)]
        @test reported(cases.pushed!, Vector{Real}, F) == [(Weak.literal, 2.0, Exit.stored)]
        # Dictionary converts value to its value type.
        @test reported(cases.keyed!, Dict{Symbol, Real}, F) == [(Weak.literal, 2.0, Exit.stored)]
        @test reported(cases.keyed!, Dict{Symbol, Float32}, F) == [(Weak.literal, 2.0, Exit.intermediate)]
        # Abstract field keeps stored value; concrete field converts it, so only intermediate widens.
        @test reported(cases.held!, cases.Holder, F) == [(Weak.literal, 2.0, Exit.stored), (Weak.literal, 2.0, Exit.intermediate)]
        @test scan(cases.global_store, F) == ([(Weak.literal, 2.0, Exit.stored, Float64, F), (Weak.literal, 2.0, Exit.intermediate, Float64, F)], false)
    end
    @testset "intermediate" begin
        @test scan(cases.inner, F) == ([(Weak.literal, 0.5, Exit.intermediate, Float64, F)], false)
    end
    @testset "type branch" begin
        @test scan(cases.branched, F) == ([(Weak.literal, 0.5, Exit.returned, Float64, F)], true)
        @test last(scan(cases.compared, F))
    end
    @testset "no finding" begin
        # Integer literal takes float input type; `Float32` is model of float stand-in.
        @test isempty(reported(cases.doubled, F))
        @test isempty(reported(cases.halved, I))
        @test isempty(reported(cases.narrowed, F))
        @test isempty(reported(cases.squared, F))
        # Index use converts to `Int`.
        @test isempty(reported(cases.following, FV, I))
        @test isempty(reported(cases.window, FV, I))
        @test isempty(reported(cases.looped, FV, I))
        @test isempty(reported(cases.counted, FV, I))
        # Size takes no part in element type; float literal makes integer input float on purpose.
        @test isempty(reported(cases.filled, I))
        @test isempty(reported(cases.kinded, I))
        # `10^12` needs `Int64`.
        @test isempty(reported(cases.huge, I))
        # Conversion to unsigned type changes kind on purpose; literals then meet `UInt64`.
        @test isempty(reported(cases.masked, I))
        @test isempty(reported(cases.unsigned, I))
        # Conversion to narrower type narrows on purpose.
        @test reported(cases.digit, I) == [(Weak.literal, 10, Exit.intermediate)]
        @test isempty(reported(cases.halfwidth, F))
        # Converted literal would make call of `Int` method throw: no finding, and other weak value still counts.
        @test isempty(reported(cases.broke_all, I))
        @test reported(cases.broke, I) == [(Weak.literal, 3, Exit.returned)]
        # Dropped weak value stays dropped: search ends after few inferences.
        signature = Tuple{typeof(cases.broke), I}
        instance, code, _, _ = something(Corset.Inference.infer(only(methods(cases.broke)), signature))
        edges = Any[]
        changes!(edges, instance, code)
        @test length(edges) < 60
        # Store into local array stays inside method.
        @test reported(cases.local_store, F) == [(Weak.literal, 2.0, Exit.intermediate)]
        # Base number type outside `Core` widens on purpose.
        @test isempty(reported(cases.precise, F))
        # Global that can change holds caller data.
        @test isempty(reported(cases.loose_global, F))
        # Swap to `Float64` breaks bound of `Picky`, so meeting test cannot tell.
        @test isempty(reported(cases.picky, F))
    end
    @testset "helpers" begin
        @test number_stand_in(Union{Nothing, F}) === F
        @test number_stand_in(Tuple{F, T} where {T}) === F
        @test isnothing(number_stand_in(Tuple{Int}))
        @test isnothing(number_stand_in(1))
        @test swapped(Union{F, Nothing}, F) == Union{Float64, Nothing}
        @test isnothing(swapped(WideningCases.Picky{F}, F))
        @test swapped(Int, F) === Int
        @test something(replacement((1, 2.0), F)) === (F(1.0f0), F(2.0f0))
        @test isnothing(replacement((1, 0.5), I))
        @test isnothing(replacement(0.5, I))
        @test isnothing(replacement(1 + 2im, F))
        @test isnothing(replacement(typemax(Int), I))
        @test call_result!(Any[], Any[typeof(+), Symbol, Symbol]) === Any
        @test ROUNDS >= 10
        @test Corset.Facts.irrational_name(3.14159) == "π"
        @test Corset.Facts.irrational_name(0.70710678) == "invsqrt2"
        @test isnothing(Corset.Facts.irrational_name(3.14))
    end
end
