using Test: @test, @testset, detect_ambiguities
using Corset.StandIns: StandIns, ArrayStandIn, DenseStandIn, FloatStandIn, FunctionStandIn, IntStandIn, model
using Supposition: Supposition, Data, @check

"""Type `type` with `stand_in` in place of `model(stand_in)`, inside type parameters and unions too."""
function swap(type::Type, stand_in::Type)::Type
    type === model(stand_in) && return stand_in
    type isa Union && return Union{swap(type.a, stand_in), swap(type.b, stand_in)}
    type isa UnionAll && return Base.rewrap_unionall(swap(Base.unwrap_unionall(type), stand_in), type)
    type isa DataType && !isempty(type.parameters) || return type
    parameters = map(parameter -> parameter isa Type ? swap(parameter, stand_in) : parameter, type.parameters)
    return Base.typename(type).wrapper{parameters...}
end

"""Operations on one number; each must infer to model result with stand-in in place of model."""
const OPERATIONS = (
    x -> x + 1, x -> x - 1.0, x -> 2x, x -> x * 0.5f0, x -> x * pi, x -> x / 2, x -> x // 2, x -> x^2, x -> x^0.5, x -> 2^x,
    x -> x^x, x -> -x, x -> abs(x), x -> abs2(x), x -> sqrt(abs(x)), x -> cbrt(x), x -> exp(x), x -> log1p(abs(x)), x -> sincos(x),
    x -> atan(x, 1), x -> hypot(x, 1), x -> inv(x), x -> sign(x) * x, x -> min(x, 1), x -> max(x, 0.5), x -> clamp(x, 0, 1),
    x -> muladd(x, 2, 1), x -> fma(x, x, x), x -> evalpoly(x, (1, 2, 3)), x -> sum((x, x, x)), x -> sum([x, x]), x -> sum([x]), x -> sum(typeof(x)[]), x -> prod([x, x]), x -> prod((x,)), x -> prod(typeof(x)[]),
    x -> collect(x:(x + 2)), x -> round(x), x -> round(Int, x), x -> trunc(Int, x), x -> floor(x), x -> ceil(Int8, x),
    x -> round(x, RoundNearestTiesAway), x -> round(x, RoundUp), x -> x % 3, x -> mod(x, 3), x -> rem(x, x), x -> divrem(x, 3),
    x -> fld(x, 2), x -> div(x, x), x -> x == 1, x -> x < 1.5, x -> isless(x, 1), x -> isequal(x, x), x -> hash(x),
    x -> zero(x) + one(x), x -> zero(typeof(x)), x -> typemax(typeof(x)), x -> float(x), x -> big(x), x -> Float64(x),
    x -> Float16(x), x -> Int(x), x -> Int64(x), x -> UInt8(x), x -> Bool(x), x -> Integer(x), x -> Signed(x), x -> complex(x) * im,
    x -> x + im, x -> x + 1 // 2, x -> x * true, x -> x + Int8(1), x -> x + UInt64(1), x -> x + Float16(1), x -> x + big(1),
    x -> isnan(x), x -> isinteger(x), x -> iszero(x), x -> signbit(x), x -> eps(x), x -> nextfloat(x), x -> exponent(x),
    x -> significand(x), x -> frexp(x), x -> modf(x), x -> ldexp(x, 2), x -> eps(typeof(x)), x -> floatmax(typeof(x)),
    x -> precision(typeof(x)), x -> x << 2, x -> x >> UInt8(1), x -> x >>> 1, x -> x & x, x -> x | 1, x -> xor(x, x), x -> ~x,
    x -> count_ones(x), x -> leading_zeros(x), x -> isodd(x), x -> gcd(x, 6), x -> lcm(x, x), x -> x % UInt8, x -> unsigned(x),
    x -> signed(x), x -> Base.Checked.checked_add(x, x), x -> Base.Checked.mul_with_overflow(x, x), x -> widen(typeof(x)),
    x -> sizeof(typeof(x)), x -> typemin(typeof(x)), x -> deg2rad(x), x -> sinpi(x), x -> string(x),
    x -> Base.decompose(x), x -> x == 1 // 3, x -> round(Int, x, RoundUp), x -> floor(Int, x), x -> nextfloat(x, 2), x -> prevfloat(x, 3),
    x -> Base.exponent_bits(typeof(x)), x -> Base.Checked.checked_abs(x), x -> Base.Checked.checked_neg(x), x -> fld(x, true),
    x -> bitrotate(x, 3), x -> factorial(x), x -> parse(typeof(x), "1"), x -> tryparse(typeof(x), "x"), x -> x^Int8(3),
)

"""
Base functions whose stand-in result type differs from model by design: float range stores stand-in where `Float32`
range stores `Float64`; stand-in has field `model`; `functionloc` line number is `Int32` by chance.
"""
const ACCEPTED = (:(:), :range, :propertynames, :functionloc)

"""Base functions sweep skips: model constructors, reflection and bit-layout functions."""
const SKIPPED = (
    :Float32, :Int32, :Core, :eval, :include, :typeof, :identity, :getfield, :setfield!, :reinterpret, :sizeof, :isbits,
    :isbitstype, :fieldtypes, :methods, :which, :objectid, :pointer_from_objref, :ntoh, :hton, :ltoh, :htol, :nameof,
    :supertype, :fieldnames, :fieldcount, :isconcretetype, :isprimitivetype, :isstructtype, :ismutable,
)

"""Exported Base functions of one or two arguments whose result type with `stand_in` differs from model result type."""
function mismatches(stand_in::Type)::Vector{Symbol}
    found = Symbol[]
    partners = (model(stand_in), Int, Float64, Bool)
    for name in names(Base)
        callee = getglobal(Base, name)
        name in SKIPPED && continue
        callee isa Function || (callee isa Type && !(callee <: Number)) || continue
        signatures = [(model(stand_in),); [(model(stand_in), partner) for partner in partners]; [(partner, model(stand_in)) for partner in partners]]
        for signature in signatures
            hasmethod(callee, Tuple{signature...}) || continue
            expected = swap(Base.infer_return_type(callee, signature), stand_in)
            replaced = map(type -> type === model(stand_in) ? stand_in : type, signature)
            expected === Union{} || Base.infer_return_type(callee, replaced) == expected || push!(found, name)
        end
    end
    return unique!(found)
end

@testset "stand-ins" begin
    @testset "no method ambiguity with Base" begin
        ambiguous = filter(detect_ambiguities(StandIns, Base; recursive = true)) do pair
            any(method -> occursin("StandIn", string(method.sig)), pair)
        end
        @test isempty(ambiguous)
    end
    @testset "promotes like model with $stand_in" for stand_in in StandIns.NUMBERS
        others = (StandIns.PARTNERS..., Rational{Int}, typeof(pi), Complex{Int}, Complex{Float32}, FloatStandIn, IntStandIn)
        for other in others
            other_model = other in StandIns.NUMBERS ? model(other) : other
            expected = swap(promote_type(model(stand_in), other_model), stand_in)
            @test promote_type(stand_in, other) == (other in StandIns.NUMBERS ? swap(expected, other) : expected)
        end
    end
    @testset "infers like model with $stand_in" for stand_in in StandIns.NUMBERS
        for operation in OPERATIONS
            expected = swap(Base.infer_return_type(operation, (model(stand_in),)), stand_in)
            @test Base.infer_return_type(operation, (stand_in,)) == expected
        end
    end
    @testset "Base functions infer like model with $stand_in" for stand_in in StandIns.NUMBERS
        @test isempty(setdiff(mismatches(stand_in), ACCEPTED))
    end
    @testset "runs like model with $stand_in" for stand_in in StandIns.NUMBERS
        values = stand_in === FloatStandIn ? Data.Floats{Float32}() : Data.Integers{Int32}()
        @check max_examples = 40 db = false function same_result(value = values)
            all(OPERATIONS) do operation
                expected = try
                    operation(value)
                catch error
                    error
                end
                got = try
                    operation(stand_in(value))
                catch error
                    error
                end
                expected isa Exception ? typeof(got) == typeof(expected) : typeof(got) == swap(typeof(expected), stand_in)
            end
        end
    end
    @testset "show and hash" begin
        @test sprint(show, FloatStandIn(1.5f0)) == "FloatStandIn(1.5)" && sprint(show, IntStandIn(Int32(3))) == "IntStandIn(3)"
        @test hash(FloatStandIn(2.0f0)) == hash(2) && hash(IntStandIn(Int32(2))) == hash(2)
        @test FloatStandIn(IntStandIn(Int32(2))) === FloatStandIn(2.0f0) && IntStandIn(FloatStandIn(2.0f0)) === IntStandIn(Int32(2))
        @test FloatStandIn(FloatStandIn(1.0f0)) === FloatStandIn(1.0f0) && FloatStandIn(pi) === FloatStandIn(Float32(pi))
        @test Unsigned(FloatStandIn(2.0f0)) === UInt(2) && maxintfloat(FloatStandIn) === FloatStandIn(maxintfloat(Float32))
        @test floatmin(FloatStandIn) === FloatStandIn(floatmin(Float32)) && Base.significand_bits(FloatStandIn) == 23
        @test float(IntStandIn) === Float64 && unsigned(IntStandIn) === UInt32 && signed(IntStandIn) === IntStandIn
    end
    @testset "$wrapper keeps array kind" for wrapper in (ArrayStandIn, DenseStandIn)
        vector = wrapper([1.0, 2.0])
        @test (vector .+ 1) isa wrapper{Float64, 1} && similar(vector, Int, (3,)) isa wrapper{Int, 1} && map(sqrt, vector) isa wrapper{Float64, 1}
        @test copy(vector) isa wrapper{Float64, 1} && wrapper([1 2; 3 4]) .* 2 isa wrapper{Int, 2}
        grown = push!(wrapper([1]), 2, 3)
        @test grown isa wrapper{Int, 1} && grown == [1, 2, 3] && append!(grown, [4]) === grown && insert!(grown, 1, 0) == 0:4
        @test pop!(grown) == 4 && popfirst!(grown) == 0 && splice!(grown, 1) == 1 && popat!(grown, 1) == 2 && grown == [3]
        @test sizehint!(grown, 10; shrink = false) === grown && resize!(grown, 2) === grown && length(deleteat!(grown, 1)) == 1
        @test prepend!(grown, [5]) === grown && pushfirst!(grown, 6) === grown && isempty(empty!(grown))
        @test setindex!(vector, 3.0, 1) === vector && vector[1] == 3.0
    end
    @testset "dense stand-in has memory layout" begin
        matrix = DenseStandIn([1.0 2.0; 3.0 4.0])
        @test strides(matrix) == (1, 2) && Base.elsize(typeof(matrix)) == 8 && view(matrix, :, 1) isa StridedVector
        @test GC.@preserve matrix unsafe_load(pointer(matrix), 2) == 3.0
    end
    @testset "function stand-in result is opaque" begin
        @test Base.infer_return_type(FunctionStandIn(), (Int,)) === Any && FunctionStandIn()(1; keyword = 2) === nothing
    end
end
