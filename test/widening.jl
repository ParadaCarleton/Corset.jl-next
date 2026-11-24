using Test: @test, @testset
using Corset: Corset
using Corset.Facts: Weak, Exit
using Corset.StandIns: FloatStandIn, IntStandIn, ArrayStandIn
using Corset.Widening: changes!, swapped, replacement, call_result!, holds_float, ROUNDS

"""Methods `Widening` scans: weak values that change input type, and code that keeps it."""
module WideningCases
    using Corset.StandIns: FloatStandIn
    const HALF = 0.5
    const COEFFICIENTS = (1.0, 2.0)
    const TABLE = Dict{Float32, Float64}()
    global untyped_total = 0.0
    global typed_total::Float64 = 0.0
    takes_double(x::Float64) = x
    mutable struct Holder
        loose::Real
        tight::Float32
    end
    """Type whose parameter bound admits float stand-in but not `Float64`."""
    struct Picky{T <: Union{Float32, FloatStandIn}}
        value::T
    end
    picked(p::Picky, y) = p.value + y
    """Method whose signature admits float stand-in but not `Float64`."""
    narrow(x::Union{Float32, FloatStandIn}, y) = x + y
    narrowly(x) = narrow(x, 0.5)
    scaled_all(xs) = xs .* 0.5
    scaled(x) = x * 0.5
    doubled(x) = 2x
    named(x) = Float64(x) + x
    narrowed(x) = Float32(x)
    halfwidth(x) = Float16(x) * x
    truncated(x) = Int(x)
    converted(x) = convert(Float64, x)
    broadcast_named(xs) = Float64.(xs)
    constant(x) = HALF * x
    precise(x) = BigFloat(x) * x
    grid(x) = [x 0.5; 1.0 2.0]
    fused(x) = muladd(x, 3.0, 2)
    lookup(x) = get(TABLE, x, 0.5)
    struct Point{A, B}
        a::A
        b::B
    end
    paired(x) = x => 0.5
    pointed(x) = Point(x, 0.5)
    tupled_pair(x) = (x, 0.5)
    promoted(x) = Float32(first(promote(x, 0.5)))
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
    function looped(xs, i)
        t = zero(eltype(xs))
        for j in 1:2i
            t += xs[j]
        end
        return t
    end
    kinded(n) = n + 0.5
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
    # Lowering temporary holds ternary value: literal kind, since slot has no name.
    picked_sum(x) = (x > 0 ? 0.5 : 1.5) + x
    # Declared result converts constant; nothing computes in wider type.
    (declared_result(x::T)::T) where {T} = x > 0 ? 0.5 : x
    # Computed result type: converted code infers `Any`, which shows no type.
    function computed_result(x::T)::promote_type(T, Float32) where {T <: Real}
        x > 0 || return -Inf32
        return x * 2
    end
    # Callee infers `Any` on stand-in: result shows no type, so change stays intermediate.
    const UNTYPED = Dict{Any, Any}()
    looked_up(v::Float64) = 1.0
    looked_up(v) = UNTYPED[v]
    fetched(x) = looked_up(x * 0.5)
    # Local container method returns: store escapes, though returned `Vector{Any}` keeps its type.
    function collected(x)
        out = Any[]
        push!(out, x * 0.5)
        return out
    end
    # Local container that stays inside: sum meets input, so change is returned.
    function summed_local(x)
        out = Any[]
        push!(out, x * 0.5)
        return sum(out)
    end
    # Abstract result and local types lower to `isa` test with conversion; neither branches on input type.
    annotated(x)::AbstractFloat = x * 0.5
    function declared_local(x)
        y::AbstractFloat = x * 0.5
        return y
    end
    # Same test written in source, then assertion: test loads its type apart.
    asserted(x) = (x isa AbstractFloat ? x * 0.5 : x)::AbstractFloat
    broke(x) = (takes_double(x * 2.0), x * 3.0)
    broke_all(x) = takes_double(x * 2.0)
    @inline static(x::T) where {T} = x * T(0.5) + 0.5
    shifted_all(xs) = xs .+ 1
    function rescaled!(x, a, s)
        x .= a .+ (x .+ 1) .* s
        return x
    end
    """Number type without conversion to other number types."""
    struct Opaque <: Real end
    Base.:*(::Opaque, x::AbstractFloat) = x
    const OPAQUE = Opaque()
    opaque(x) = OPAQUE * x
    # Callee `T` follows input type: inference folds `T(4)`, though value is no weak value.
    struct Knobs{T}
        scale::T
    end
    (bracketed(knobs::Knobs, x::T)::T) where {T <: Real} = knobs.scale * x + log(T(4))
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

"""Compiler edges `changes!` collects for `f` on `arguments`: one batch per inference it runs."""
function edge_count(f::Function, arguments::Type...)::Int
    instance, code, _, _ = something(Corset.Inference.infer(only(methods(f)), Tuple{typeof(f), arguments...}))
    edges = Any[]
    changes!(edges, instance, code)
    return length(edges)
end

const F, I, FV, IV = FloatStandIn, IntStandIn, ArrayStandIn{FloatStandIn, 1}, ArrayStandIn{IntStandIn, 1}

@testset "widening" begin
    cases = WideningCases
    @testset "weak values that escape" begin
        @test scan(cases.scaled, F) == ([(Weak.literal, 0.5, Exit.returned, Float64, F)], false)
        @test reported(cases.named, F) == [(Weak.name, Float64, Exit.returned)]
        @test reported(cases.converted, F) == [(Weak.name, Float64, Exit.returned)]
        @test reported(cases.broadcast_named, FV) == [(Weak.name, Float64, Exit.returned)]
        # Lazy broadcast keeps argument types; meeting test compares arrays it materializes to.
        @test reported(cases.scaled_all, FV) == [(Weak.literal, 0.5, Exit.returned)]
        @test reported(cases.constant, F) == [(Weak.constant, 0.5, Exit.returned)]
        @test reported(cases.rooted, F) == [(Weak.constant, sqrt(2), Exit.returned)]
        @test reported(cases.circled, F) == [(Weak.constant, 2π, Exit.returned)]
        @test reported(cases.poly, F) == [(Weak.literal, (1.0, 2.0, 3.0), Exit.returned)]
        @test reported(cases.tupled, F) == [(Weak.constant, (1.0, 2.0), Exit.returned)]
        # Second literal meets input only once first converts.
        @test reported(cases.chained, F) == [(Weak.literal, 2.0, Exit.returned), (Weak.literal, 1.0, Exit.returned)]
        @test length(reported(cases.horner, F)) == 5
        @test scan(cases.summed, FV) == ([(Weak.variable, 0, Exit.returned, Union{Int64, F}, F)], false)
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
        # Store into local array stays inside method.
        @test reported(cases.local_store, F) == [(Weak.literal, 2.0, Exit.intermediate)]
    end
    @testset "intermediate" begin
        @test scan(cases.inner, F) == ([(Weak.literal, 0.5, Exit.intermediate, Float64, F)], false)
        # Tuple that `promote` returns carries no number itself; its element does.
        @test scan(cases.promoted, F) == ([(Weak.literal, 0.5, Exit.intermediate, Float64, F)], false)
    end
    @testset "type branch" begin
        @test scan(cases.branched, F) == ([(Weak.literal, 0.5, Exit.returned, Float64, F)], true)
        @test last(scan(cases.compared, F))
        @test scan(cases.annotated, F) == ([(Weak.literal, 0.5, Exit.returned, Float64, F)], false)
        @test scan(cases.declared_local, F) == ([(Weak.literal, 0.5, Exit.returned, Float64, F)], false)
        @test last(scan(cases.asserted, F))
    end
    @testset "lowering temporaries" begin
        @test reported(cases.picked_sum, F) == [(Weak.literal, 0.5, Exit.returned), (Weak.literal, 1.5, Exit.returned)]
        @test isempty(reported(cases.declared_result, F)) && isempty(reported(cases.computed_result, F))
        @test reported(cases.fetched, F) == [(Weak.literal, 0.5, Exit.intermediate)]
    end
    @testset "local container" begin
        @test scan(cases.collected, F) == ([(Weak.literal, 0.5, Exit.stored, Float64, F)], false)
        @test only(first(scan(cases.summed_local, F)))[3] != Exit.stored
    end
    @testset "no finding" begin
        # Integer literal takes float input type; `Float32` is model of float stand-in.
        @test isempty(reported(cases.doubled, F))
        @test isempty(reported(cases.narrowed, F))
        @test isempty(reported(cases.squared, F))
        # Julia promotes small integers to `Int` on purpose, so integer input takes no part.
        @test isempty(reported(cases.doubled, I))
        @test isempty(reported(cases.summed, IV))
        @test isempty(reported(cases.kinded, I))
        @test isempty(reported(cases.following, FV, I))
        @test isempty(reported(cases.looped, FV, I))
        # Conversion to narrower type or other kind changes input on purpose.
        @test isempty(reported(cases.halfwidth, F))
        @test isempty(reported(cases.truncated, F))
        # Input does not absorb weak value: default takes table value type; pair, tuple and struct keep each type.
        @test isempty(reported(cases.lookup, F))
        @test isempty(reported(cases.paired, F))
        @test isempty(reported(cases.pointed, F))
        @test isempty(reported(cases.tupled_pair, F))
        # Converted literal would make call of `Float64` method throw: no finding, and other weak value still counts.
        @test isempty(reported(cases.broke_all, F))
        @test reported(cases.broke, F) == [(Weak.literal, 3.0, Exit.returned)]
        # Dropped weak value stays dropped, so search ends after few inferences.
        @test edge_count(cases.broke, F) < 60
        # Base number type outside `Core` widens on purpose.
        @test isempty(reported(cases.precise, F))
        # Global that can change holds caller data.
        @test isempty(reported(cases.loose_global, F))
        # Swap to `Float64` breaks bound of `Picky` or signature of `narrow`, so meeting test cannot tell.
        @test isempty(reported(cases.picky, F))
        @test isempty(reported(cases.narrowly, F))
        # Integer literal changes only argument type of lazy broadcast; materialized array keeps input type.
        @test isempty(reported(cases.shifted_all, FV))
        @test isempty(reported(cases.rescaled!, FV, F, F))
        # Constant of number type without conversion cannot take input type.
        @test isempty(reported(cases.opaque, F))
        # `log(T(4))` folds to `Float64` for integer `T`, yet follows input type `T`; float input is field of `knobs`.
        @test isempty(reported(cases.bracketed, cases.Knobs{F}, I))
    end
    @testset "helpers" begin
        @test holds_float(Union{Nothing, F})
        @test holds_float(Tuple{F, T} where {T})
        @test !holds_float(Tuple{Int})
        @test !holds_float(I)
        @test !holds_float(1)
        @test swapped(Union{F, Nothing}) == Union{Float64, Nothing}
        @test isnothing(swapped(WideningCases.Picky{F}))
        @test swapped(Int) === Int
        # Variable bound holds stand-in too; member or parameter that bound rejects fails whole type.
        @test holds_float(Base.RefValue{T} where {T <: F}) && !holds_float(Base.RefValue{T} where {T <: I})
        @test swapped(Base.RefValue{T} where {T <: F}) == (Base.RefValue{T} where {T <: Float64})
        @test isnothing(swapped(Union{WideningCases.Picky{F}, Nothing})) && isnothing(swapped(Base.RefValue{WideningCases.Picky{F}}))
        @test isnothing(swapped(Base.RefValue{T} where {T <: WideningCases.Picky{F}}))
        @test something(replacement((1, 2.0))) === (F(1.0f0), F(2.0f0))
        @test isnothing(replacement((1, 2im)))
        @test isnothing(replacement(1 + 2im))
        @test isnothing(replacement(WideningCases.Opaque()))
        @test call_result!(Any[], Any[typeof(+), Symbol, Symbol]) === Any
        @test ROUNDS >= 10
        @test Corset.Facts.irrational_name(3.14159) == "π"
        @test Corset.Facts.irrational_name(0.70710678) == "invsqrt2"
        @test isnothing(Corset.Facts.irrational_name(3.14))
    end
end
