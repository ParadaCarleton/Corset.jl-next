"""
Stand-in types: concrete types that stand for any caller type of their kind.
Each wraps its model type (narrowest Base type of kind) and promotes like it.
"""
module StandIns

import Random

export FloatStandIn, IntStandIn, ArrayStandIn, FunctionStandIn, OpaqueResult, model_type, has_stand_in

"Float stand-in; promotes like `Float32`: absorbs integers, loses to `Float64`."
struct FloatStandIn <: AbstractFloat
    model::Float32
    FloatStandIn(x::Float32) = new(x)
end

"Integer stand-in; promotes like `Int32`: loses to `Int`, absorbs `Int8`, `Int16` and `Bool`."
struct IntStandIn <: Signed
    model::Int32
    IntStandIn(x::Int32) = new(x)
end

const NumberStandIn = Union{FloatStandIn, IntStandIn}

"Array stand-in; keeps its container kind through `similar` and broadcast."
struct ArrayStandIn{T, N} <: AbstractArray{T, N}
    data::Array{T, N}
end

"Opaque result of function stand-in; any later use is outside analysis."
struct OpaqueResult end

"Function stand-in; returns `OpaqueResult` for every call."
struct FunctionStandIn <: Function end
(::FunctionStandIn)(args...; kwargs...) = OpaqueResult()

model(x::FloatStandIn)::Float32 = x.model
model(x::IntStandIn)::Int32 = x.model
model(::Type{FloatStandIn}) = Float32
model(::Type{IntStandIn}) = Int32

"Rewrap model result in stand-in when it has model type; else pass through."
wrap(r::Float32)::FloatStandIn = FloatStandIn(r)
wrap(r::Int32)::IntStandIn = IntStandIn(r)
wrap(r::Tuple) = map(wrap, r)
wrap(r) = r

# Constructors and conversions.
FloatStandIn(x::FloatStandIn) = x
IntStandIn(x::IntStandIn) = x
for (S, M) in ((FloatStandIn, Float32), (IntStandIn, Int32))
    for T in (
            Bool, Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128,
            Float16, Float32, Float64, BigInt, BigFloat, Rational, Irrational,
        )
        T === M || @eval (::Type{$S})(x::$T) = $S($M(x))
    end
    S === IntStandIn || @eval (::Type{$S})(x::IntStandIn) = $S($M(x.model))
    S === FloatStandIn || @eval (::Type{$S})(x::FloatStandIn) = $S($M(x.model))
    for T in (
            Bool, Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128,
            Float16, Float32, Float64, BigInt, BigFloat,
        )
        @eval (::Type{$T})(x::$S) = $T(x.model)
    end
    @eval Base.Rational{T}(x::$S) where {T <: Base.BitInteger} = Rational{T}(x.model)
end
Base.Rational(x::IntStandIn) = Rational(x.model)
Base.Int(x::FloatStandIn, r::RoundingMode) = round(Int, x.model, r)

# Promotion: mirror the model type, then map model back to stand-in.
const PROMOTE_PARTNERS = (
    Bool, Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64,
    UInt128, Float16, Float32, Float64, BigInt, BigFloat,
)
standin_of(T::Type, S::Type)::Type = T === model(S) ? S : T
for S in (FloatStandIn, IntStandIn), T in PROMOTE_PARTNERS
    @eval Base.promote_rule(::Type{$S}, ::Type{$T}) = standin_of(promote_type(model($S), $T), $S)
end
Base.promote_rule(::Type{FloatStandIn}, ::Type{IntStandIn}) = FloatStandIn
Base.promote_rule(::Type{FloatStandIn}, ::Type{<:Rational}) = FloatStandIn
Base.promote_rule(::Type{IntStandIn}, ::Type{Rational{T}}) where {T <: Integer} = Rational{promote_type(IntStandIn, T)}
# Base special-cases Float32 against irrationals; the float stand-in must follow.
Base.promote_rule(::Type{<:AbstractIrrational}, ::Type{FloatStandIn}) = FloatStandIn
Base.promote_rule(::Type{<:AbstractIrrational}, ::Type{IntStandIn}) = Float64

# Arithmetic and math, forwarded to the model type.
const BINARY = (
    :+, :-, :*, :/, :^, :rem, :mod, :div, :fld, :cld, :min, :max, :atan, :hypot, :copysign,
    :flipsign, :\,
)
const BINARY_INT = (:&, :|, :xor, :gcd, :lcm, :<<, :>>, :>>>)
const COMPARE = (:(==), :<, :<=, :isless, :isequal, :!=)
const UNARY = (
    :-, :abs, :abs2, :sqrt, :cbrt, :exp, :exp2, :exp10, :expm1, :log, :log2, :log10, :log1p,
    :sin, :cos, :tan, :asin, :acos, :atan, :sinh, :cosh, :tanh, :asinh, :acosh, :atanh,
    :sinpi, :cospi, :sign, :float, :inv, :round, :trunc, :floor, :ceil, :nextfloat, :prevfloat,
    :eps, :significand, :exponent, :sincos, :frexp, :modf, :signbit, :isnan, :isinf, :isfinite,
    :isinteger, :iszero, :isone, :~, :count_ones, :leading_zeros, :trailing_zeros, :isodd,
    :iseven, :bswap, :deg2rad, :rad2deg, :conj, :real, :imag, :transpose, :adjoint, :widen,
)
for S in (FloatStandIn, IntStandIn)
    for f in BINARY
        isdefined(Base, f) && @eval Base.$f(a::$S, b::$S) = wrap($f(a.model, b.model))
    end
    for f in COMPARE
        @eval Base.$f(a::$S, b::$S) = $f(a.model, b.model)
    end
    for f in UNARY
        isdefined(Base, f) && @eval Base.$f(a::$S) = wrap($f(a.model))
    end
    @eval begin
        Base.:^(a::$S, b::Base.BitInteger) = wrap(a.model^b)
        Base.ldexp(a::$S, n::Integer) = wrap(ldexp(a.model, n))
        Base.hash(a::$S, h::UInt) = hash(a.model, h)
        Base.round(a::$S, r::RoundingMode{:Nearest}) = wrap(round(a.model, r))
        Base.round(a::$S, r::RoundingMode{:Down}) = wrap(round(a.model, r))
        Base.round(a::$S, r::RoundingMode{:Up}) = wrap(round(a.model, r))
        Base.round(a::$S, r::RoundingMode{:ToZero}) = wrap(round(a.model, r))
        Base.round(::Type{T}, a::$S) where {T <: Integer} = round(T, a.model)
        Base.round(::Type{T}, a::$S, r::RoundingMode) where {T <: Integer} = round(T, a.model, r)
        Base.trunc(::Type{T}, a::$S) where {T <: Integer} = trunc(T, a.model)
        Base.floor(::Type{T}, a::$S) where {T <: Integer} = floor(T, a.model)
        Base.ceil(::Type{T}, a::$S) where {T <: Integer} = ceil(T, a.model)
        Base.zero(::Type{$S}) = $S(zero(model($S)))
        Base.one(::Type{$S}) = $S(one(model($S)))
        Base.typemin(::Type{$S}) = $S(typemin(model($S)))
        Base.typemax(::Type{$S}) = $S(typemax(model($S)))
        Base.eps(::Type{$S}) = wrap(eps(model($S)))
        Base.sizeof(::Type{$S}) = sizeof(model($S))
        Base.widen(::Type{$S}) = widen(model($S))
        Base.float(::Type{$S}) = $S === IntStandIn ? Float64 : FloatStandIn
        Base.show(io::IO, a::$S) = print(io, $(string(nameof(S))), "(", a.model, ")")
        Base.string(a::$S) = string(a.model)
        Base.decompose(a::$S) = Base.decompose(a.model)
        Base.unsigned(a::$S) = unsigned(a.model)
        Base.signed(a::$S) = wrap(signed(a.model))
        Base.:%(a::$S, ::Type{T}) where {T <: Base.BitInteger} = a.model % T
        Random.rand(rng::Random.AbstractRNG, ::Random.SamplerType{$S}) = $S(rand(rng, model($S)))
    end
end
for f in BINARY_INT
    @eval Base.$f(a::IntStandIn, b::IntStandIn) = wrap($f(a.model, b.model))
end
for f in (:<<, :>>, :>>>)
    @eval Base.$f(a::IntStandIn, b::Int) = wrap($f(a.model, b))
end
Base.:/(a::IntStandIn, b::IntStandIn) = a.model / b.model
Base.divrem(a::IntStandIn, b::IntStandIn) = wrap(divrem(a.model, b.model))
Base.fma(a::FloatStandIn, b::FloatStandIn, c::FloatStandIn) = wrap(fma(a.model, b.model, c.model))
Base.muladd(a::FloatStandIn, b::FloatStandIn, c::FloatStandIn) = wrap(muladd(a.model, b.model, c.model))
Base.floatmin(::Type{FloatStandIn}) = FloatStandIn(floatmin(Float32))
Base.floatmax(::Type{FloatStandIn}) = FloatStandIn(floatmax(Float32))
Base.maxintfloat(::Type{FloatStandIn}) = FloatStandIn(maxintfloat(Float32))
Base.precision(::Type{FloatStandIn}; base::Integer = 2) = precision(Float32; base)
Base.exponent_bits(::Type{FloatStandIn}) = Base.exponent_bits(Float32)
Base.significand_bits(::Type{FloatStandIn}) = Base.significand_bits(Float32)
Base.uinttype(::Type{FloatStandIn}) = UInt32
Base.unsigned(::Type{IntStandIn}) = UInt32
Base.signed(::Type{IntStandIn}) = IntStandIn
Base.Checked.checked_add(a::IntStandIn, b::IntStandIn) = wrap(Base.Checked.checked_add(a.model, b.model))
Base.Checked.checked_mul(a::IntStandIn, b::IntStandIn) = wrap(Base.Checked.checked_mul(a.model, b.model))
Base.Checked.checked_sub(a::IntStandIn, b::IntStandIn) = wrap(Base.Checked.checked_sub(a.model, b.model))
Base.Checked.add_with_overflow(a::IntStandIn, b::IntStandIn) = wrap(Base.Checked.add_with_overflow(a.model, b.model))
Base.Checked.mul_with_overflow(a::IntStandIn, b::IntStandIn) = wrap(Base.Checked.mul_with_overflow(a.model, b.model))

# Array stand-in: minimal AbstractArray interface plus kind-preserving similar and broadcast.
Base.size(a::ArrayStandIn) = size(a.data)
Base.IndexStyle(::Type{<:ArrayStandIn}) = IndexLinear()
Base.@propagate_inbounds Base.getindex(a::ArrayStandIn, i::Int) = a.data[i]
Base.@propagate_inbounds Base.setindex!(a::ArrayStandIn, v, i::Int) = (a.data[i] = v; a)
Base.similar(a::ArrayStandIn, ::Type{T}, dims::Dims) where {T} = ArrayStandIn(similar(a.data, T, dims))
Base.resize!(a::ArrayStandIn{T, 1}, n::Integer) where {T} = (resize!(a.data, n); a)
Base.push!(a::ArrayStandIn{T, 1}, v) where {T} = (push!(a.data, v); a)
Base.BroadcastStyle(::Type{<:ArrayStandIn{T, N}}) where {T, N} = Broadcast.ArrayStyle{ArrayStandIn{Any, N}}()
Base.similar(bc::Broadcast.Broadcasted{Broadcast.ArrayStyle{ArrayStandIn{Any, N}}}, ::Type{T}) where {T, N} =
    ArrayStandIn(similar(Array{T, N}, axes(bc)))

"Map stand-in types inside `T` to their model types: `Float32`, `Int32`, `Array`."
model_type(T) = T
model_type(::Type{FloatStandIn}) = Float32
model_type(::Type{IntStandIn}) = Int32
model_type(::Type{ArrayStandIn{T, N}}) where {T, N} = Array{model_type(T), N}
function model_type(T::DataType)
    T <: Type && T isa DataType && T.name === Type.body.name && return Type{model_type(T.parameters[1])}
    isempty(T.parameters) && return T
    return try
        T.name.wrapper{map(model_type, T.parameters)...}
    catch
        T
    end
end
model_type(T::Union) = Union{model_type(T.a), model_type(T.b)}

"True when `T` mentions a stand-in type anywhere in its parameters."
has_stand_in(T) = false
has_stand_in(::Type{<:Union{NumberStandIn, ArrayStandIn, FunctionStandIn, OpaqueResult}}) = true
has_stand_in(T::DataType) = T <: Union{NumberStandIn, ArrayStandIn, FunctionStandIn, OpaqueResult} ||
    any(has_stand_in, T.parameters)
has_stand_in(T::Union) = has_stand_in(T.a) || has_stand_in(T.b)
has_stand_in(T::UnionAll) = has_stand_in(Base.unwrap_unionall(T))

"Number stand-in mentioned in `T` (scalar or element), or `nothing`."
number_stand_in(T) = nothing
function number_stand_in(T::DataType)
    T <: NumberStandIn && return T
    for p in T.parameters
        s = number_stand_in(p)
        s === nothing || return s
    end
    return nothing
end
number_stand_in(T::Union) = something(number_stand_in(T.a), number_stand_in(T.b), Some(nothing))
export number_stand_in, NumberStandIn

end
