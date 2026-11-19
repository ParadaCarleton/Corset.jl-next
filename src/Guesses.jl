"""
Type guesses for missing annotations (`annotation` fix), from types inference sees: argument types at package call
sites, literal default values, and result types. Each observed type widens to its family: numbers to `Real` (`Integer`
when all integer), arrays to `AbstractVector{<:Real}`, struct to nearest abstract supertype. Guess holds at most three
families, and stays only when its type holds every observed type.
"""
module Guesses

using ..Facts: Facts, PackageFacts, AnnotationGuess, Edit, Tier, MethodSite, SyntaxFile, SyntaxNode, Span
using ..Facts: children_of, kind_name, identifier_name, source, signature
using ..StandIns: StandIns

"""Most families one guess may join in `Union`; more means code takes too many kinds to name."""
const FAMILIES = 3

"""Abstract types that name their family as is, after numbers and arrays."""
const NAMED = (Number, AbstractString, Symbol, AbstractChar, AbstractDict, AbstractSet, NamedTuple, Tuple, Function, Type)

"""Name `scope` binds to type constructor of `type`; `nothing` when bare name reaches other value there."""
function bound_name(type::DataType, scope::Module)::Union{Nothing, String}
    name = type.name.name
    return isdefined(scope, name) && getglobal(scope, name) === type.name.wrapper ? string(name) : nothing
end

"""Family text of array element `type`: number families widen to `Real`, so array guess takes every real element."""
function element_text(type::Any, scope::Module)::Union{Nothing, String}
    type isa Type && type !== Union{} && type <: Real && return "Real"
    return family_text(type, scope)
end

"""
Family text of observed `type`, stand-ins as models: `Bool`, `Integer`, `Real`, array of element family, named family
(`AbstractString`), `Nothing`, `Missing`, or nearest abstract supertype of struct (struct itself under `Any`).
`nothing` for `Any`, union, unbound name or other type.
"""
function family_text(type::Any, scope::Module)::Union{Nothing, String}
    type = StandIns.model_type(type)
    (type === Nothing || type === Missing) && return string(type)
    (type isa DataType || type isa UnionAll) && type <: AbstractArray && return array_text(type, scope)
    (type isa DataType && type !== Any) || return nothing
    type <: Bool && return "Bool"
    type <: Integer && return "Integer"
    type <: Real && return "Real"
    for family in NAMED
        type <: family && return string(nameof(family))
    end
    parent = supertype(type)
    return bound_name(parent === Any ? type : parent, scope)
end

"""
Dimension count of array `type` and element bound; count `nothing` when open. Open stand-in model is `Array` family,
whose type variables are element and count (`Array{T, 1} where T <: AbstractString`).
"""
function array_shape(type::Type)::Tuple{Union{Nothing, Int}, Any}
    type isa DataType && return ndims(type), eltype(type)
    body = Base.unwrap_unionall(type)
    if body isa DataType && body <: Array
        element, dimensions = body.parameters
        return dimensions isa Int ? dimensions : nothing, element isa TypeVar ? element.ub : element
    end
    return (applicable(ndims, type) ? ndims(type) : nothing), Any
end

"""Family text of array `type`: `AbstractVector`, `AbstractMatrix` or `AbstractArray`, with element family and count."""
function array_text(type::Type, scope::Module)::Union{Nothing, String}
    dimensions, element = array_shape(type)
    name = dimensions == 1 ? "AbstractVector" : dimensions == 2 ? "AbstractMatrix" : "AbstractArray"
    # Open count names no count: `AbstractArray` takes any.
    suffix = isnothing(dimensions) || dimensions <= 2 ? "" : ", $dimensions"
    element === Any && return isempty(suffix) ? name : "$name{<:Any$suffix}"
    inner = element_text(element, scope)
    isnothing(inner) && return nothing
    return "$name{<:$inner$suffix}"
end

"""Members of `type`: union members, or `type` alone."""
members(type::Any)::Vector{Any} = type isa Union ? [members(type.a); members(type.b)] : Any[type]

"""Type `text` names in `scope`; `nothing` when text does not evaluate to type there."""
function named_type(text::String, scope::Module)::Union{Nothing, Type}
    named = try
        Core.eval(scope, Meta.parse(text))
    catch error
        error isa Union{UndefVarError, TypeError} || rethrow()
        nothing
    end
    return named isa Type ? named : nothing
end

"""
Annotation text that holds every one of `observed` types in `scope`: families joined in order seen, `Real` absorbing
`Integer` and `Bool`, at most `FAMILIES` in `Union`, `Nothing` and `Missing` last. `nothing` when observed type has no
family, families exceed limit, or text does not hold every observed type.
"""
function annotation_text(observed::Vector{Any}, scope::Module)::Union{Nothing, String}
    pieces = String[]
    for type in observed, member in members(type)
        text = family_text(member, scope)
        isnothing(text) && return nothing
        text in pieces || push!(pieces, text)
    end
    isempty(pieces) && return nothing
    "Real" in pieces && filter!(piece -> !(piece in ("Integer", "Bool")), pieces)
    "Integer" in pieces && filter!(!=("Bool"), pieces)
    length(pieces) > FAMILIES && return nothing
    # Optional value reads `Union{Real, Nothing}`: absence goes last.
    sort!(pieces; by = piece -> piece in ("Nothing", "Missing"))
    text = length(pieces) == 1 ? only(pieces) : "Union{$(join(pieces, ", "))}"
    named = named_type(text, scope)
    isnothing(named) && return nothing
    for type in observed
        StandIns.model_type(type) <: named || return nothing
    end
    return text
end

"""Untyped name of argument `node`, through default value; `nothing` for typed, splat, tuple and `_` argument."""
function argument_name(node::SyntaxNode)::Union{Nothing, SyntaxNode}
    kind_name(node) in ("=", "kw") && (node = children_of(node)[1])
    return kind_name(node) == "Identifier" && identifier_name(node) != "_" ? node : nothing
end

"""Type of literal default value of argument `node` in `file` (`x = 1` gives `Int`, `x = nothing` gives `Nothing`); else `nothing`."""
function default_type(file::SyntaxFile, node::SyntaxNode)::Union{Nothing, Type}
    kind_name(node) in ("=", "kw") || return nothing
    value = Meta.parse(source(file, children_of(node)[2]); raise = false)
    value === :nothing && return Nothing
    return value isa Union{Number, AbstractString, AbstractChar} ? typeof(value) : nothing
end

"""Widest evidence text; wider parametric type prints name only (`Tuple{…}`)."""
const EVIDENCE_WIDTH = 40

"""Evidence for message: first three distinct `types` as `scope` prints them, stand-ins as models."""
function evidence(types::Vector{Any}, scope::Module)::Vector{String}
    texts = String[]
    for type in types
        model = StandIns.model_type(type)
        text = sprint(show, model; context = :module => scope)
        length(text) > EVIDENCE_WIDTH && model isa DataType && (text = "$(nameof(model)){…}")
        length(texts) < 3 && !(text in texts) && push!(texts, text)
    end
    return texts
end

"""
Whether stand-ins of declared argument `type` cover its values: concrete type, real number, or array of real numbers.
Stand-ins of `Number` model no `Complex`; arrays of `Any` hold only numbers.
"""
covered(type::Type)::Bool = isconcretetype(type) || type <: Real || type <: AbstractArray{<:Real}

"""Whether own inference of `site` saw every argument type its method declares (`covered`)."""
function covered(site::MethodSite)::Bool
    arguments = length(Facts.tuple_parameters(site.method.sig)) - 1
    return all(position -> covered(something(Facts.argument_type(site.method, position))), 1:arguments)
end

"""
Annotation guesses for untyped positional arguments and missing result types of package methods. Evidence: `observed`
signature and result type per method, and literal default values. Methods of one definition (lowering makes one per
omitted default value) share evidence. Result guess is `likely` when own inference saw every argument type: no
keyword argument (inference sees default only), every method `covered` and none in `incomplete` (skipped or failed
signature, or code that tests type). Else `breaking`.
"""
function annotation_guesses(package::PackageFacts, observed::IdDict{Method, Vector{Tuple{Type, Type}}}, incomplete::Set{Method})::Vector{AnnotationGuess}
    definitions, order = IdDict{SyntaxNode, Vector{MethodSite}}(), SyntaxNode[]
    for site in package.methods
        isnothing(site.node) && continue
        haskey(definitions, site.node) || push!(order, site.node)
        push!(get!(Vector{MethodSite}, definitions, site.node), site)
    end
    found = AnnotationGuess[]
    for node in order
        sites = definitions[node]
        parts = signature(node)
        isnothing(parts) && continue
        file, scope, seen = first(sites).file, first(sites).method.module, Tuple{Type, Type}[]
        for site in sites
            append!(seen, get(observed, site.method, Tuple{Type, Type}[]))
        end
        positional = SyntaxNode[part for part in parts.arguments if kind_name(part) != "parameters"]
        keywords = SyntaxNode[child for part in parts.arguments if kind_name(part) == "parameters" for child in children_of(part)]
        for (position, part) in enumerate(positional)
            name = argument_name(part)
            isnothing(name) && continue
            types = Any[]
            for (call_signature, _) in seen
                arguments = Facts.tuple_parameters(call_signature)
                length(arguments) > position && push!(types, arguments[position + 1])
            end
            default = default_type(file, part)
            isnothing(default) || push!(types, default)
            text = isempty(types) ? nothing : annotation_text(types, scope)
            isnothing(text) && continue
            span = Facts.span(file, name)
            push!(found, AnnotationGuess(span, Edit(span, "$(source(file, name))::$text"), text, evidence(types, scope), Tier.breaking))
        end
        parts.typed && continue
        results = Any[result for (_, result) in seen if result !== Union{}]
        text = isempty(results) ? nothing : annotation_text(results, scope)
        isnothing(text) && continue
        call = Facts.span(file, parts.call)
        seen_all = isempty(keywords) && all(site -> covered(site) && !(site.method in incomplete), sites)
        tier = seen_all ? Tier.likely : Tier.breaking
        push!(found, AnnotationGuess(call, Edit(Span(call.file, call.last_byte + 1, call.last_byte, call.precision), "::$text"), text, evidence(results, scope), tier))
    end
    return found
end

end
