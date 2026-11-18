using Test: @test, @testset
using Corset: Corset
using Corset.StandIns: ArrayStandIn, DenseStandIn, FloatStandIn, FunctionStandIn, IntStandIn
using Corset.Signatures: LIMIT, Provenance, method_signatures, struct_stand_ins, argument_provenance

"""Methods whose stand-in signatures tests check."""
module SignatureCases
    abstract type Shape end
    struct Circle{T <: Real} <: Shape
        radius::T
    end
    struct Square <: Shape
        side::Float64
    end
    struct Box{T}
        item::T
    end
    area(shape::Shape) = shape
    scale(x::Real, factor::Integer) = x * factor
    total(values::AbstractVector{<:Real}) = sum(values)
    first_item(values::AbstractVector) = values[1]
    both(x::T, y::T) where {T <: Real} = x + y
    apply(f::Function, x) = f(x)
    kind(::Type{T}) where {T <: AbstractFloat} = T
    strided(values::StridedMatrix{Float64}) = values
    many(xs::Real...) = sum(xs)
    pair(xs::Vararg{Real, 2}) = xs
    text(s::AbstractString) = s
    plain(x::Int) = x
    unbox(box::Box) = box.item
    free(x::T) where {T} = x
    bounded(x::T) where {Int32 <: T <: Integer} = x
    wide(a::Real, b::Real, c::Real, d::Real) = a + b + c + d
    nested(values::V) where {T <: Real, V <: AbstractVector{T}} = values
    counts(values::AbstractMatrix{T}) where {T <: Integer} = values
    cube(values::AbstractArray{Float64, 3}) = values
    tensor(values::AbstractArray{Float64, 4}) = values
    exact(x::T) where {T <: Int} = x
    mixed(x::T, n::Int) where {T} = x
    pick(shape::T) where {T <: Shape} = shape
    struct Bounded{E <: Real, V <: AbstractVector{E}}
        values::V
    end
    paired(::Type{E}, bounded::Bounded{E, V}) where {E <: Real, V <: AbstractVector} = bounded
    struct Holder{S <: Circle}
        inner::S
    end
    hold(holder::Holder) = holder.inner
    struct Sized{N}
        values::NTuple{N, Float64}
    end
    measure(sized::Sized) = sized.values
    listed(values::Vector{Any}) = values
    listed_deep(table::Dict{Symbol, Vector{Any}}) = table
    first_listed(values::AbstractVector{Vector{Any}}) = values[1]
    abstract type Tree end
    struct Node{C <: Tree} <: Tree
        child::C
    end
end

const CASES = SignatureCases
const STRUCTS = struct_stand_ins(Type[CASES.Circle, CASES.Square, CASES.Box, CASES.Holder, CASES.Sized])

"""Stand-in signatures of only method of `name` in `SignatureCases`."""
signatures_of(name::Symbol) = method_signatures(only(methods(getglobal(CASES, name))), STRUCTS)

"""Signature tuple type for function `name` with `arguments`."""
call(name::Symbol, arguments::Any...)::Type = Tuple{typeof(getglobal(CASES, name)), arguments...}

"""Methods with distinct declared bounds, one per index, for each stand-in path (numbers, arrays, structs), and with `index` arguments."""
module CompileCases
    abstract type Shape end
    struct Square <: Shape end
    for index in 1:6
        @eval $(Symbol(:numbers, index))(x::Union{Real, Val{$index}}) = x
        @eval $(Symbol(:arrays, index))(x::AbstractVector{<:Union{Real, Val{$index}}}) = x
        @eval $(Symbol(:structs, index))(x::Union{Shape, Val{$index}}) = x
        @eval $(Symbol(:arity, index))($((:($(Symbol(:x, position))::Real) for position in 1:index)...)) = nothing
    end
end

include("compilation.jl")

@testset "stand-in signatures" begin
    # Unbounded `T` of `Box` takes bound `Any`; `Holder` takes `Circle` stand-ins of round before.
    # `Sized{Any}` has field type `Union{}`, so it has no values and no stand-in.
    # Union argument cut at `LIMIT` reaches most structs and data: stand-ins without bound first, then first
    # stand-in of each struct before second of any.
    @test STRUCTS == Type[
        CASES.Circle{FloatStandIn}, CASES.Square, CASES.Holder{CASES.Circle{FloatStandIn}},
        CASES.Circle{IntStandIn}, CASES.Holder{CASES.Circle{IntStandIn}}, CASES.Box{Any},
    ]
    # Recursive bound nests one level per round, so rounds end.
    @test only(struct_stand_ins(Type[CASES.Node])) == CASES.Node{CASES.Node{CASES.Node{CASES.Node{CASES.Tree}}}}
    expected = Dict(
        :area => [call(:area, CASES.Circle{FloatStandIn}), call(:area, CASES.Square), call(:area, CASES.Circle{IntStandIn})],
        :scale => [call(:scale, FloatStandIn, IntStandIn), call(:scale, IntStandIn, IntStandIn)],
        :total => [call(:total, ArrayStandIn{FloatStandIn, 1}), call(:total, ArrayStandIn{IntStandIn, 1})],
        :first_item => [call(:first_item, ArrayStandIn{Any, 1})],
        :both => [call(:both, FloatStandIn, FloatStandIn), call(:both, IntStandIn, IntStandIn)],
        :kind => [call(:kind, Type{FloatStandIn})],
        :strided => [call(:strided, DenseStandIn{Float64, 2})],
        :many => [call(:many, Vararg{FloatStandIn}), call(:many, Vararg{IntStandIn})],
        :pair => [call(:pair, a, b) for b in (FloatStandIn, IntStandIn) for a in (FloatStandIn, IntStandIn)],
        :plain => [call(:plain, Int)],
        :nested => [call(:nested, ArrayStandIn{FloatStandIn, 1}), call(:nested, ArrayStandIn{IntStandIn, 1})],
        :counts => [call(:counts, ArrayStandIn{IntStandIn, 2})],
        :cube => [call(:cube, ArrayStandIn{Float64, 3})],
        :exact => [call(:exact, Int)],
        :unbox => [call(:unbox, CASES.Box{Any})],
        :hold => [call(:hold, CASES.Holder{CASES.Circle{FloatStandIn}}), call(:hold, CASES.Holder{CASES.Circle{IntStandIn}})],
    )
    @testset "$name" for (name, signatures) in expected
        found = signatures_of(name)
        @test found.signatures == signatures && isempty(found.bare) && !found.over_limit
    end
    @testset "argument without stand-in keeps declared type" begin
        @test signatures_of(:apply).signatures == [call(:apply, FunctionStandIn, Any)] && signatures_of(:apply).bare == [2]
        @test signatures_of(:text).signatures == [call(:text, AbstractString)] && signatures_of(:text).bare == [1]
        @test signatures_of(:tensor).signatures == [call(:tensor, AbstractArray{Float64, 4})] && signatures_of(:tensor).bare == [1]
        @test signatures_of(:measure).signatures == [call(:measure, CASES.Sized)] && signatures_of(:measure).bare == [1]
        free = signatures_of(:free)
        @test free.signatures == [only(methods(CASES.free)).sig] && free.bare == [1]
        # Integer stand-in is no supertype of `Int32`, so lower bound leaves `T` free.
        @test signatures_of(:bounded).signatures == [only(methods(CASES.bounded)).sig] && signatures_of(:bounded).bare == [1]
        # Concrete argument of free signature keeps its type without counting as bare.
        @test signatures_of(:mixed).signatures == [only(methods(CASES.mixed)).sig] && signatures_of(:mixed).bare == [1]
    end
    @testset "combinations stop at limit" begin
        wide = signatures_of(:wide)
        @test length(wide.signatures) == LIMIT && wide.over_limit && first(wide.signatures) == call(:wide, FloatStandIn, FloatStandIn, FloatStandIn, FloatStandIn)
        many_shapes = method_signatures(only(methods(CASES.area)), repeat(STRUCTS, 4))
        @test length(many_shapes.signatures) == LIMIT && many_shapes.over_limit
        many_variables = method_signatures(only(methods(CASES.pick)), repeat(STRUCTS, 4))
        @test length(many_variables.signatures) == LIMIT && many_variables.over_limit
    end
    @testset "compilation independent of signature count" begin
        # Closure capturing type value has type parameter `Type{value}`, so it once compiled anew for each signature.
        # `Iterators.product` over splatted options compiled once per argument count.
        cases = [only(methods(getglobal(CompileCases, Symbol(kind, index)))) for index in 1:6, kind in (:numbers, :arrays, :structs, :arity)]
        structs = Type[CompileCases.Square]
        signatures_of(methods::Vector{Method})::Nothing = foreach(method -> method_signatures(method, structs), methods)
        warm, rest = cases[1, :], vec(cases[2:end, :])
        signatures_of(warm)
        before = specializations(Corset.Signatures, Base)
        signatures_of(rest)
        @test specializations(Corset.Signatures, Base) == before
    end
    @testset "struct bound rejects stand-in" begin
        # Array stand-in with element `Any` fits method bound of `V`, not struct bound `V <: AbstractVector{E}`.
        found = signatures_of(:paired)
        @test found.signatures == [Tuple{typeof(CASES.paired), Type{element}, CASES.Bounded{element, V}} where {V <: AbstractVector} for element in (FloatStandIn, IntStandIn)]
        @test found.bare == [2]
    end
    @testset "argument provenance" begin
        code, opaque, opt_out = Provenance.code, Provenance.opaque, Provenance.opt_out
        provenances(name::Symbol, opted::Vector{Int})::Vector{Vector{Provenance.T}} = [argument_provenance(only(methods(getglobal(CASES, name))), signature, true, opted) for signature in signatures_of(name).signatures]
        # Stand-in with open part Corset chose: function, array element `Any`, struct parameter at bound.
        @test provenances(:apply, Int[]) == [[code, opaque, code]] && provenances(:apply, [2]) == [[code, opaque, opt_out]]
        @test provenances(:first_item, Int[]) == [[code, opaque]] && provenances(:unbox, Int[]) == [[code, opaque]]
        # Stand-ins without open part, and declared concrete types: code.
        @test provenances(:total, Int[]) == [[code, code], [code, code]] && provenances(:kind, Int[]) == [[code, code]]
        @test provenances(:plain, Int[]) == [[code, code]] && provenances(:many, Int[]) == [[code, code], [code, code]]
        # Declared type kept: abstract one and bounded variable are Corset choice; unbounded variable is code.
        @test provenances(:text, Int[]) == [[code, opaque]] && provenances(:bounded, Int[]) == [[code, opaque]]
        @test provenances(:free, Int[]) == [[code, code]] && provenances(:mixed, Int[]) == [[code, code, code]]
        @test provenances(:nested, Int[]) == [[code, code], [code, code]] && provenances(:measure, Int[]) == [[code, opaque]]
        # Declared concrete type with `Any` parameter at any depth opts out.
        @test provenances(:listed, Int[]) == [[code, opt_out]] && provenances(:listed_deep, Int[]) == [[code, opt_out]]
        # Array stand-in with open part below its element: whole argument is Corset choice.
        @test provenances(:first_listed, Int[]) == [[code, opaque]]
        # Signature call reaches carries caller types: only function and array stand-ins are Corset choice.
        @test argument_provenance(only(methods(CASES.first_item)), call(:first_item, AbstractVector), false, Int[]) == [code, code]
        @test argument_provenance(only(methods(CASES.first_item)), call(:first_item, ArrayStandIn{Any, 1}), false, Int[]) == [code, opaque]
        @test argument_provenance(only(methods(CASES.apply)), call(:apply, FunctionStandIn, Any), false, [2]) == [code, opaque, code]
        @test argument_provenance(only(methods(CASES.unbox)), call(:unbox, CASES.Box{Any}), false, Int[]) == [code, code]
    end
    @testset "concrete struct list" begin
        # Caller may pass `Vector{DataType}`.
        @test method_signatures(only(methods(CASES.area)), DataType[CASES.Square]).signatures == [call(:area, CASES.Square)]
    end
end
