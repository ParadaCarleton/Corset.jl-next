"""
Stand-in types: types that stand for any caller type of their kind, so inference of generic method sees one known type.
Each wraps model type, narrowest Base type of its kind, and promotes like it: `Float32`, `Int32`, `Array`.
Base fast paths for model types skip stand-in, so inference takes generic path, as user type would.
Array stand-in for any element keeps element open (`ArrayStandIn{<:Any, 1}`): no element type decides code.
"""
module StandIns

"""Float stand-in; promotes like `Float32`: absorbs integers and irrationals, loses to `Float64`."""
struct FloatStandIn <: AbstractFloat
    model::Float32
    FloatStandIn(model::Float32)::FloatStandIn = new(model)
end

"""Integer stand-in; promotes like `Int32`: absorbs `Bool`, `Int8` and `Int16`, loses to `Int`."""
struct IntStandIn <: Signed
    model::Int32
    IntStandIn(model::Int32)::IntStandIn = new(model)
end

"""Array stand-in for `AbstractArray` bound; `similar` and broadcast keep it, as for caller array type."""
struct ArrayStandIn{T, N} <: AbstractArray{T, N}
    data::Array{T, N}
end

"""Array stand-in for `DenseArray` and `StridedArray` bounds: `ArrayStandIn` interface plus memory layout."""
struct DenseStandIn{T, N} <: DenseArray{T, N}
    data::Array{T, N}
end

"""
Wrapper of array constructor (`zeros`, `Vector{T}`): call converts result to stand-in array type `W`, as `similar` of
argument of that type would build it. `inference` stage puts it in place of hard-coded constructor.
"""
struct Templated{W, F} <: Function
    constructor::F
    ((::Type{Templated{W}})(constructor::Any)::Templated{W}) where {W} = new{W, Core.Typeof(constructor)}(constructor)
end

((made::Templated{W})(arguments::Any...)::W) where {W} = W(made.constructor(arguments...))

"""
Function stand-in: each call returns `Any` to inference, so later code stays analyzed and its values give no findings.
Call has unknown compiler effects, like any callee: compaction keeps it, and caller is never `effect_free`.
"""
struct FunctionStandIn <: Function end

(::FunctionStandIn)(arguments::Any...; keywords...)::Any = Base.inferencebarrier(Returns(nothing))(arguments...; keywords...)

"""Number stand-ins."""
const NUMBERS = (FloatStandIn, IntStandIn)

"""Model type of number stand-in: narrowest Base type of its kind."""
model(::Type{FloatStandIn})::Type{Float32} = Float32
model(::Type{IntStandIn})::Type{Int32} = Int32

"""
`type` with each stand-in replaced by its model, parameters and union members included: `ArrayStandIn{FloatStandIn, 1}`
gives `Vector{Float32}`.
Function stand-in has no model and stays.
"""
model_type(@nospecialize(type::Any))::Any = modeled(type, IdDict{TypeVar, TypeVar}())

"""`model_type` of `type`; `variables` maps each type variable to one with modeled bounds (`P <: ArrayStandIn` of view)."""
function modeled(@nospecialize(type::Any), variables::IdDict{TypeVar, TypeVar})::Any
    type isa TypeVar && return get(variables, type, type)
    type in NUMBERS && return model(type)
    type isa Union && return Union{modeled(type.a, variables), modeled(type.b, variables)}
    if type isa UnionAll
        variable = TypeVar(type.var.name, modeled(type.var.lb, variables), modeled(type.var.ub, variables))
        variables[type.var] = variable
        return UnionAll(variable, modeled(type.body, variables))
    end
    type isa DataType || return type
    parameters = Any[modeled(parameter, variables) for parameter in type.parameters]
    type <: Union{ArrayStandIn, DenseStandIn} && return Array{parameters...}
    return isempty(parameters) ? type : type.name.wrapper{parameters...}
end

"""Whether `type` is array stand-in, element open or not: `ArrayStandIn{<:Any, 1}`, `DenseStandIn{FloatStandIn, 2}`."""
array_stand_in(@nospecialize(type::Any))::Bool = (type isa DataType || type isa UnionAll) && type <: Union{ArrayStandIn, DenseStandIn}

"""Base number types stand-ins convert to and promote with."""
const PARTNERS = (Bool, Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128, Float16, Float32, Float64, BigInt, BigFloat)

"""Base functions of one number that stand-ins forward to model, when model has method."""
const UNARY = (
    :-, :abs, :abs2, :sqrt, :cbrt, :exp, :exp2, :exp10, :expm1, :log, :log2, :log10, :log1p, :sin, :cos, :tan, :asin, :acos,
    :atan, :sinh, :cosh, :tanh, :asinh, :acosh, :atanh, :sinpi, :cospi, :sincos, :sign, :inv, :round, :trunc, :floor, :ceil,
    :nextfloat, :prevfloat, :eps, :significand, :exponent, :frexp, :modf, :signbit, :isnan, :isinf, :isfinite, :isinteger,
    :iszero, :isone, :~, :count_ones, :leading_zeros, :trailing_zeros, :isodd, :iseven, :bswap, :deg2rad, :rad2deg,
    :issubnormal, :mod2pi, :bitreverse, :bitstring, :invmod, :uabs,
)

"""Base functions of two numbers of one type that stand-ins forward to model, when model has method."""
const BINARY = (
    :+, :-, :*, :/, :\, :^, :rem, :mod, :div, :fld, :cld, :divrem, :fldmod, :min, :max, :minmax, :atan, :hypot, :copysign,
    :flipsign, :&, :|, :xor, :gcd, :lcm, :(==), :<, :<=, :isless, :isequal,
)

"""Result of model operation with stand-in in place of model value; tuples element by element; other values unchanged."""
rewrap(result::Float32)::FloatStandIn = FloatStandIn(result)
rewrap(result::Int32)::IntStandIn = IntStandIn(result)
rewrap(result::Tuple)::Tuple = map(rewrap, result)
rewrap(@nospecialize(result::Any))::Any = result

for stand_in in NUMBERS
    model_type = model(stand_in)
    @eval (::Type{$stand_in})(number::$stand_in)::$stand_in = number
    for partner in PARTNERS
        partner === model_type || @eval (::Type{$stand_in})(number::$partner)::$stand_in = $stand_in($model_type(number))
        @eval (::Type{$partner})(number::$stand_in)::$partner = $partner(number.model)
        promoted = promote_type(model_type, partner) === model_type ? stand_in : promote_type(model_type, partner)
        @eval Base.promote_rule(::Type{$stand_in}, ::Type{$partner})::Type{$promoted} = $promoted
    end
    for name in UNARY
        hasmethod(getglobal(Base, name), Tuple{model_type}) || continue
        @eval Base.$name(number::$stand_in)::Any = rewrap(Base.$name(number.model))
    end
    for name in BINARY
        hasmethod(getglobal(Base, name), Tuple{model_type, model_type}) || continue
        @eval Base.$name(left::$stand_in, right::$stand_in)::Any = rewrap(Base.$name(left.model, right.model))
    end
    @eval begin
        Base.hash(number::$stand_in, seed::UInt)::UInt = hash(number.model, seed)
        Base.round(::Type{T}, number::$stand_in) where {T <: Integer} = round(T, number.model)
        Base.round(::Type{T}, number::$stand_in, mode::RoundingMode) where {T <: Integer} = round(T, number.model, mode)
        Base.trunc(::Type{T}, number::$stand_in) where {T <: Integer} = trunc(T, number.model)
        Base.floor(::Type{T}, number::$stand_in) where {T <: Integer} = floor(T, number.model)
        Base.ceil(::Type{T}, number::$stand_in) where {T <: Integer} = ceil(T, number.model)
        Base.zero(::Type{$stand_in})::$stand_in = $stand_in(zero($model_type))
        Base.one(::Type{$stand_in})::$stand_in = $stand_in(one($model_type))
        Base.typemin(::Type{$stand_in})::$stand_in = $stand_in(typemin($model_type))
        Base.typemax(::Type{$stand_in})::$stand_in = $stand_in(typemax($model_type))
        Base.sizeof(::Type{$stand_in})::Int = sizeof($model_type)
        Base.widen(::Type{$stand_in})::DataType = widen($model_type)
        Base.show(io::IO, number::$stand_in)::Nothing = print(io, $(string(nameof(stand_in))), "(", number.model, ")")
    end
end

FloatStandIn(number::IntStandIn)::FloatStandIn = FloatStandIn(Float32(number.model))
IntStandIn(number::FloatStandIn)::IntStandIn = IntStandIn(Int32(number.model))
FloatStandIn(number::AbstractIrrational)::FloatStandIn = FloatStandIn(Float32(number))
for kind in (Integer, Signed, Unsigned)
    @eval (::Type{$kind})(number::FloatStandIn)::$kind = $kind(number.model)
end
Base.promote_rule(::Type{FloatStandIn}, ::Type{IntStandIn})::Type{FloatStandIn} = FloatStandIn
"""Irrational with float stand-in gives float stand-in, as Base gives `Float32` for `Float32` (`irrationals.jl`)."""
Base.promote_rule(::Type{<:AbstractIrrational}, ::Type{FloatStandIn})::Type{FloatStandIn} = FloatStandIn
Base.float(::Type{IntStandIn})::Type{Float64} = Float64
Base.float(number::IntStandIn)::Float64 = float(number.model)
Base.eps(::Type{FloatStandIn})::FloatStandIn = FloatStandIn(eps(Float32))
Base.floatmin(::Type{FloatStandIn})::FloatStandIn = FloatStandIn(floatmin(Float32))
Base.floatmax(::Type{FloatStandIn})::FloatStandIn = FloatStandIn(floatmax(Float32))
Base.maxintfloat(::Type{FloatStandIn})::FloatStandIn = FloatStandIn(maxintfloat(Float32))
Base.decompose(number::FloatStandIn)::Tuple = Base.decompose(number.model)
Base.tryparse(::Type{FloatStandIn}, text::AbstractString)::Union{Nothing, FloatStandIn} = rewrap(tryparse(Float32, text))
Base.precision(::Type{FloatStandIn}; base::Integer = 2)::Int = precision(Float32; base)
Base.exponent_bits(::Type{FloatStandIn})::Int = Base.exponent_bits(Float32)
Base.significand_bits(::Type{FloatStandIn})::Int = Base.significand_bits(Float32)
# Base reduces other rounding modes to these four; user float types define these only.
for mode in (:Nearest, :ToZero, :Up, :Down)
    @eval Base.round(number::FloatStandIn, mode::RoundingMode{$(QuoteNode(mode))})::FloatStandIn = rewrap(round(number.model, mode))
end
Base.fma(left::FloatStandIn, right::FloatStandIn, addend::FloatStandIn)::FloatStandIn = rewrap(fma(left.model, right.model, addend.model))
Base.muladd(left::FloatStandIn, right::FloatStandIn, addend::FloatStandIn)::FloatStandIn = rewrap(muladd(left.model, right.model, addend.model))
Base.ldexp(number::FloatStandIn, power::Integer)::FloatStandIn = rewrap(ldexp(number.model, power))
Base.nextfloat(number::FloatStandIn, steps::Integer)::FloatStandIn = rewrap(nextfloat(number.model, steps))
Base.prevfloat(number::FloatStandIn, steps::Integer)::FloatStandIn = rewrap(prevfloat(number.model, steps))
Base.unsigned(::Type{IntStandIn})::Type{UInt32} = UInt32
Base.signed(::Type{IntStandIn})::Type{IntStandIn} = IntStandIn
Base.unsigned(number::IntStandIn)::UInt32 = unsigned(number.model)
Base.signed(number::IntStandIn)::IntStandIn = number
(Base.:%(number::IntStandIn, ::Type{T})::T) where {T <: Base.BitInteger} = number.model % T
"""`sum` and `prod` widen small integers to `Int` (`reduce.jl`)."""
Base.add_sum(left::IntStandIn, right::IntStandIn)::Int = Int(left) + Int(right)
Base.mul_prod(left::IntStandIn, right::IntStandIn)::Int = Int(left) * Int(right)
Base.reduce_first(::typeof(Base.add_sum), number::IntStandIn)::Int = Int(number)
Base.reduce_first(::typeof(Base.mul_prod), number::IntStandIn)::Int = Int(number)
Base.reduce_empty(::typeof(Base.add_sum), ::Type{IntStandIn})::Int = zero(Int)
Base.reduce_empty(::typeof(Base.mul_prod), ::Type{IntStandIn})::Int = one(Int)
# Base reduces every shift count to `UInt`; user integer types define this method only.
for name in (:<<, :>>, :>>>)
    @eval Base.$name(number::IntStandIn, shift::UInt)::IntStandIn = rewrap(Base.$name(number.model, shift))
end
for name in (:checked_add, :checked_sub, :checked_mul, :checked_div, :checked_rem, :checked_fld, :checked_mod, :checked_cld, :add_with_overflow, :sub_with_overflow, :mul_with_overflow)
    @eval Base.Checked.$name(left::IntStandIn, right::IntStandIn)::Any = rewrap(Base.Checked.$name(left.model, right.model))
end
for name in (:checked_abs, :checked_neg)
    @eval Base.Checked.$name(number::IntStandIn)::IntStandIn = rewrap(Base.Checked.$name(number.model))
end
"""Integer `div` in rounding mode Base reduces other modes to; user integer types define this one."""
Base.div(left::IntStandIn, right::IntStandIn, ::RoundingMode{:ToZero})::IntStandIn = div(left, right)
Base.bitrotate(number::IntStandIn, shift::Integer)::IntStandIn = rewrap(bitrotate(number.model, shift))
"""`factorial` widens small integers to `Int` (`combinatorics.jl`)."""
Base.factorial(number::IntStandIn)::Int = factorial(Int(number))

for wrapper in (ArrayStandIn, DenseStandIn)
    @eval begin
        Base.size(array::$wrapper)::Tuple = size(array.data)
        Base.IndexStyle(::Type{<:$wrapper})::IndexLinear = IndexLinear()
        Base.@propagate_inbounds Base.getindex(array::$wrapper, index::Int) = array.data[index]
        Base.@propagate_inbounds Base.setindex!(array::$wrapper, element, index::Int) = (array.data[index] = element; array)
        Base.similar(array::$wrapper, ::Type{T}, dims::Dims) where {T} = $wrapper(similar(array.data, T, dims))
        Base.BroadcastStyle(::Type{<:$wrapper})::Broadcast.ArrayStyle{$wrapper} = Broadcast.ArrayStyle{$wrapper}()
        Base.similar(broadcast::Broadcast.Broadcasted{Broadcast.ArrayStyle{$wrapper}}, ::Type{T}) where {T} =
            $wrapper(similar(Array{T}, axes(broadcast)))
    end
    # Vector stand-in resizes like `Vector`, so code that grows argument stays analyzed.
    for name in (:push!, :pushfirst!, :append!, :prepend!, :insert!, :deleteat!, :empty!, :resize!, :sizehint!)
        @eval Base.$name(vector::$wrapper{T, 1}, arguments...; keywords...) where {T} = (Base.$name(vector.data, arguments...; keywords...); vector)
    end
    # These return removed elements, so result is data result.
    for name in (:pop!, :popfirst!, :popat!, :splice!)
        @eval Base.$name(vector::$wrapper{T, 1}, arguments...) where {T} = Base.$name(vector.data, arguments...)
    end
end
(Base.unsafe_convert(::Type{Ptr{T}}, array::DenseStandIn{T})::Ptr{T}) where {T} = Base.unsafe_convert(Ptr{T}, array.data)
(Base.elsize(::Type{<:DenseStandIn{T, N}})::Int) where {T, N} = Base.elsize(Array{T, N})

end
