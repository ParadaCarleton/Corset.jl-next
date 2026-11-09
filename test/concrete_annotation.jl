# `concrete-annotation` and `any-supertype`: every annotation is generic, and every struct has an abstract supertype.

"""The details of the `concrete-annotation` sites in `text`, with names resolved in `scope`."""
function annotation_details(text::AbstractString, scope::Module = Base)::Vector{String}
    tree = write_tree(mktempdir(), ["source.jl" => text])
    return [site.detail for site in Corset.concrete_annotations(parsed(joinpath(tree, "source.jl")), scope)]
end

"""A module holding the definitions in `text`, which exports `exported` and declares `declared` public."""
function module_with(text::AbstractString, exported::Symbol, declared::Symbol)::Module
    scope = Module(:AnnotationFixture)
    Base.include_string(scope, text)
    Core.eval(scope, Expr(:export, exported))
    Core.eval(scope, Expr(:public, declared))
    return scope
end

"""The details of the `any-supertype` sites in `text`."""
function supertype_details(text::AbstractString)::Vector{String}
    tree = write_tree(mktempdir(), ["source.jl" => text])
    return [site.detail for site in Corset.any_supertype_sites(parsed(joinpath(tree, "source.jl")))]
end

@testset "concrete-annotation: method arguments" begin
    for text in ("f(x::Float64) = x\n", "f(x::String) = x\n", "f(x::Vector{Float64}) = x\n", "f(; x::Int = 1) = x\n", "f(xs::Int...) = xs\n", "f(::Int) = 1\n")
        @test !isempty(annotation_details(text))
    end
    for text in (
            "f(x::Real) = x\n", "f(x::AbstractVector{<:Real}) = x\n", "f(x::T) where {T <: Real} = x\n", "f(x::AbstractVector{T}) where {T} = x\n",
            "f(x::Bool, y::Nothing, z::Symbol, w::Union{Nothing, Missing}) = x\n", "f(x::Tuple{Vararg{Real}}) = x\n", "f(x) = x\n", "f(x::Real...) = x\n",
        )
        @test annotation_details(text) == String[]
    end
    @test annotation_details("f(x::Float64) = x\n") == ["`Float64` is concrete; name an abstract type or a type variable"]
    @test annotation_details("f(x::Union{Nothing, Float64}) = x\n") == ["`Float64` is concrete; name an abstract type or a type variable"]
    @test annotation_details("f(x::Base.Vector{T}) where {T} = x\n") == ["`Base.Vector` is concrete; name an abstract type or a type variable"]
    @test annotation_details("f(x::Base.AbstractVector{<:Real}) = x\n") == String[]
    @test annotation_details("f(x::Unknown.Thing, y::Base.Nonexistent) = x\n") == String[]
    @test annotation_details("f(x::Base.Missing) = x\n") == String[]
    @test annotation_details("f(x::g.(1)) = x\n") == String[]
    @test annotation_details("f(x::sum, y::Base.sum) = x\n") == String[]
    @test annotation_details("f(x::Color)::Color = x\n", module_with("@enum Color red green\nstruct Other end\n", :Color, :Other)) == String[]
    @test annotation_details("f(x::Vector{T}) where {T} = push!(x, first(x))\n") == String[]
    @test annotation_details("f(x::Vector{Float64}) = push!(x, 1)\n") == ["type argument `Float64` fixes the parameter exactly; write `<:Float64` or a type variable"]
end

@testset "concrete-annotation: where bounds and results" begin
    @test annotation_details("f(x::T) where {T <: Float64} = x\n") == ["`Float64` is concrete; name an abstract type or a type variable"]
    @test annotation_details("f(x::T) where {T <: Real} = x\n") == String[]
    @test annotation_details("f(x::T) where {T >: Int} = x\n") == String[]
    @test annotation_details("f(x::Real)::Float64 = x\n") == ["`Float64` is concrete; name an abstract type or a type variable"]
    @test annotation_details("f(x::Real)::Real = x\n") == String[]
    @test annotation_details("f(x::Real)::Bool = true\n") == String[]
    @test annotation_details("Some(x::Real)::Some = Some{Real}(x)\n") == String[]
    @test annotation_details("(f(x::T)::T) where {T} = x\n") == String[]
end

@testset "concrete-annotation: arguments that are not specialized" begin
    @test annotation_details("f(::Type) = 1\n") == ["bare `Type` is not specialized on; write `Type{T}`"]
    @test annotation_details("f(::Type{T}) where {T} = T\n") == String[]
    @test annotation_details("f(f::Function, x) = map(f, x)\n") ==
        ["`Function` argument `f` is passed through unspecialized; annotate it with a type variable (`f::F`)"]
    @test annotation_details("f(f::Function, x) = f(x)\n") == String[]
    @test annotation_details("f(f::Function, x) = f.(x)\n") == String[]
    @test annotation_details("f(f::F, x) where {F} = map(f, x)\n") == String[]
    @test length(annotation_details("f(f::Function) = 1\n")) == 1
    @test annotation_details("f(xs::Vararg) = 1\n") == ["bare `Vararg` is not specialized on; write `Vararg{T, N}`"]
    @test annotation_details("f(xs::Vararg{T, N}) where {T, N} = 1\n") == String[]
    @test annotation_details("f(x::Real, xs::Tuple{Vararg{Real}}) = 1\n") == String[]
    @test annotation_details("f(x::NTuple{3, Float64}) = 1\n") == ["`Float64` is concrete; name an abstract type or a type variable"]
end

@testset "concrete-annotation: type arguments" begin
    fixed = "type argument `Float64` fixes the parameter exactly; write `<:Float64` or a type variable"
    @test annotation_details("f(x::AbstractVector{Float64}) = x\n") == [fixed]
    @test annotation_details("f(x::AbstractVector{Real}) = x\n") == ["type argument `Real` fixes the parameter exactly; write `<:Real` or a type variable"]
    @test annotation_details("f(x::AbstractVector{<:Real}) = x\n") == String[]
    @test annotation_details("f(x::AbstractVector{T}) where {T <: Real} = x\n") == String[]
    @test annotation_details("f(x::AbstractVector{<:Float64}) = x\n") == ["`Float64` is concrete; name an abstract type or a type variable"]
    @test annotation_details("f(x::AbstractVector{Symbol}) = x\n") == String[]
    @test annotation_details("f(x::AbstractMatrix{T}, ::Val{3}, ::Val{:a}) where {T} = x\n") == String[]
    @test annotation_details("f(x::AbstractArray{T, 2}) where {T} = x\n") == String[]
    @test annotation_details("f(x::AbstractVector{Vector{T}}) where {T} = x\n") == ["type argument `Vector{T}` fixes the parameter exactly; write `<:` of a generic type or a type variable"]
    @test annotation_details("f(x::AbstractVector{<:AbstractVector{<:Real}}) = x\n") == String[]
    @test annotation_details("f(x::Val{(:a, :b)}) = x\n") == String[]
    @test annotation_details("f(x::AbstractVector{typeof(1)}) = x\n") == String[]
end

@testset "concrete-annotation: fields of public structs" begin
    text = "struct Exposed{T}\n    parameter::T\n    built::Vector{T}\n    union::Union{Nothing, T}\n    flag::Bool\n    name::Symbol\n    untyped\nend\n" *
        "struct Declared\n    fixed::Float64\n    abstract::Real\n    container::Vector{Float64}\n    nested::Vector{Vector{Int}}\nend\n" *
        "struct Hidden\n    fixed::Float64\nend\n"
    scope = module_with(text, :Exposed, :Declared)
    @test annotation_details(text, scope) == [
        "field `fixed::Float64` of public struct `Declared` must be a type parameter",
        "field `abstract::Real` of public struct `Declared` must be a type parameter",
        "field `container::Vector{Float64}` of public struct `Declared` must be a type parameter",
        "field `nested::Vector{Vector{Int}}` of public struct `Declared` must be a type parameter",
    ]
    @test annotation_details("struct Hidden\n    fixed::Float64\nend\n", scope) == String[]
    @test annotation_details("struct Exposed{T}\n    x::T\n    const y::Float64\nend\n", scope) == ["field `y::Float64` of public struct `Exposed` must be a type parameter"]
    @test annotation_details("struct Exposed{T}\n    x::Val{3}\n    y::Val{T}\nend\n", scope) == String[]
    @test annotation_details("struct Absent\n    x::Float64\nend\n", scope) == String[]
    @test annotation_details("struct Exposed <: Real\n    x::Float64\nend\n", scope) == ["field `x::Float64` of public struct `Exposed` must be a type parameter"]
end

@testset "any-supertype: a struct declares an abstract supertype" begin
    @test supertype_details("struct Plain\n    x\nend\n") == ["struct `Plain` has supertype `Any`; declare an abstract supertype"]
    @test supertype_details("mutable struct Plain{T}\n    x::T\nend\n") == ["struct `Plain` has supertype `Any`; declare an abstract supertype"]
    @test supertype_details("struct Explicit <: Any end\n") == ["struct `Explicit` has supertype `Any`; declare an abstract supertype"]
    @test supertype_details("struct Derived <: AbstractFloat end\nstruct Parametric{T} <: Number end\n") == String[]
    @test supertype_details("abstract type Base_ end\n") == String[]
end

@testset "concrete-annotation: the former name concrete-arg still works" begin
    @test Corset.canonical_rule_name("concrete-arg") == "concrete-annotation"
    @test Corset.canonical_rule_name("annotation") == "annotation"
    tree = write_tree(mktempdir(), ["source.jl" => "f(x::Float64) = x # lint: concrete-arg  kept\ng(x::Float64) = x\n"])
    comments = parsed(joinpath(tree, "source.jl")).comments
    @test [comment.rule for comment in comments] == ["concrete-annotation"]
    sites = Corset.concrete_annotations(parsed(joinpath(tree, "source.jl")), Base)
    kept, opted = Corset.unopted(sites, "concrete-annotation", Dict(joinpath(tree, "source.jl") => comments))
    @test ([site.line for site in kept], opted) == ([2], 1)
    baseline = write_tree(mktempdir(), ["baseline.toml" => "[concrete-arg]\n\"src/a.jl\" = 2\n"])
    @test Corset.read_baseline(joinpath(baseline, "baseline.toml")) == Dict("concrete-annotation" => Dict("src/a.jl" => 2))
    project = write_tree(mktempdir(), ["Project.toml" => "[preferences.Corset.levels]\nconcrete-arg = \"deny\"\n"])
    @test Corset.load_config(project).levels == Dict("concrete-annotation" => :deny)
    config = Corset.load_config(write_tree(mktempdir(), ["Project.toml" => ""]))
    @test Corset.with_overrides(config, false, ["concrete-arg" => :deny], nothing).levels == Dict("concrete-annotation" => :deny)
end
