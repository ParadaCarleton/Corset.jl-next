"""
`missing-interface` (F92): struct misses method its Base interface requires; first call that needs it throws.

## Description
Reports package struct that misses method Base interface requires:
- `AbstractArray` subtype: `size(A)`, and scalar `getindex` with one `Int` per dimension.
  Linear `getindex(A, i::Int)` counts too when type sets own `IndexStyle`.
- `AbstractString` subtype: `ncodeunits(s)`, `codeunit(s, i::Int)`, `isvalid(s, i::Int)`, `iterate(s, i::Int)`.
- Struct that package `Base.iterate` method takes: `length(x)` when its `IteratorSize` is `HasLength`; `length(x)` and
  `size(x)` when it is `HasShape`. Default `IteratorSize` is `HasLength`. Return type inference finds trait.
Method on interface type itself, as `getindex(A::AbstractArray, I...)`, is Base fallback and does not count.

## Rationale
Julia checks interface at first call. Missing method throws there, often inside `show`, `collect` or `map`.

## Example
```julia
struct Ones <: AbstractVector{Float64}
    length::Int
end
Base.size(ones::Ones)::Tuple{Int} = (ones.length,)
```

## Alternative
```julia
Base.getindex(ones::Ones, index::Int)::Float64 = (checkbounds(ones, index); 1.0)
```

## Limitations
Struct without `struct` form in package files passes, as struct from macro.
Array with own `IndexStyle` passes with either `getindex` form, also when style is `IndexCartesian`.
Iterator whose `IteratorSize` inference cannot settle to one trait passes, as trait that depends on type parameter.
`AbstractArray` subtype gets array interface only; it covers iteration.
"""
module MissingInterface

using ...Facts

const NAME = Symbol("missing-interface")

"""Methods `AbstractString` subtype needs: function, and count of `Int` arguments after string."""
const STRING_METHODS = ((ncodeunits, 0), (codeunit, 1), (isvalid, 1), (iterate, 1))

"""Signature of call `callee(arguments...)`, wrapped in type variables of struct `type` that `arguments` use."""
call(callee::Union{Function, Type}, type::Type, arguments::Any...)::Type = Base.rewrap_unionall(Tuple{Core.Typeof(callee), arguments...}, type)

"""Whether method of `callee` covers `query` with first argument narrower than `interface`; methods on `interface` or wider are fallbacks."""
function implemented(callee::Union{Function, Type}, query::Type, interface::Type)::Bool
    # Loop: closure over type values compiles once per value.
    for method in methods(callee)
        query <: method.sig && !(interface <: argument_type(method, 1)) && return true
    end
    return false
end

"""Text of call to `callee` on struct `name` with `arguments` after it: `getindex(::Ones, ::Int)`."""
call_text(callee::Union{Function, Type}, name::String, arguments::Vector{String})::String = "$(nameof(callee))($(join(["::$name"; arguments], ", ")))"

"""Fix text that defines `gaps` in `Base`."""
define(gaps::Vector{String})::String = "define " * join(("`Base.$gap`" for gap in gaps), " and ")

"""Dimension count of array struct `body`: `Int`, or type variable of struct."""
function rank(body::DataType)::Union{Int, TypeVar}
    array = body
    while array.name !== Base.unwrap_unionall(AbstractArray).name
        array = supertype(array)
    end
    return array.parameters[2]
end

"""Calls `AbstractArray` struct `type` named `name` misses: `size`, and scalar `getindex`."""
function array_gaps(type::Type, name::String)::Vector{String}
    body, dimensions = Base.unwrap_unionall(type), rank(Base.unwrap_unionall(type))
    gaps = implemented(size, call(size, type, body), AbstractArray) ? String[] : [call_text(size, name, String[])]
    cartesian = implemented(getindex, call(getindex, type, body, Vararg{Int, dimensions}), AbstractArray)
    styled = implemented(IndexStyle, call(IndexStyle, type, Type{body}), Type{<:AbstractArray})
    linear = styled && implemented(getindex, call(getindex, type, body, Int), AbstractArray)
    indices = dimensions isa Int ? fill("::Int", dimensions) : ["::Vararg{Int, $dimensions}"]
    cartesian || linear || push!(gaps, call_text(getindex, name, indices))
    return gaps
end

"""Calls `AbstractString` struct `type` named `name` misses."""
function string_gaps(type::Type, name::String)::Vector{String}
    body, gaps = Base.unwrap_unionall(type), String[]
    # Loop: comprehension over type value compiles once per value.
    for (callee, count) in STRING_METHODS
        implemented(callee, call(callee, type, body, fill(Int, count)...), AbstractString) || push!(gaps, call_text(callee, name, fill("::Int", count)))
    end
    return gaps
end

"""Methods iterator with `IteratorSize` of inferred type `sized` needs: none unless trait settles to `HasLength` or `HasShape`."""
sized_methods(sized::Type)::Vector{Function} = sized === Union{} || !(sized <: Union{Base.HasLength, Base.HasShape}) ? Function[] : sized <: Base.HasShape ? [length, size] : [length]

"""Calls iterator struct `type` named `name` misses, as `IteratorSize` of inferred type `sized` needs; methods on `Any` are fallbacks."""
function iteration_gaps(type::Type, name::String, sized::Type)::Vector{String}
    body, gaps = Base.unwrap_unionall(type), String[]
    # Loop: comprehension over type value compiles once per value.
    for callee in sized_methods(sized)
        implemented(callee, call(callee, type, body), Any) || push!(gaps, call_text(callee, name, String[]))
    end
    return gaps
end

"""First argument types of package `Base.iterate` methods, with their sites; structs of those types are iterators."""
function iterated_types(package::PackageFacts)::Vector{Tuple{Type, MethodSite}}
    found = Tuple{Type, MethodSite}[]
    for site in package.methods
        tuple_parameters(site.method.sig)[1] === typeof(Base.iterate) || continue
        type = argument_type(site.method, 1)
        isnothing(type) || push!(found, (type, site))
    end
    return found
end

"""Label on supertype in head of struct `site`, which opts into `interface`."""
supertype_label(site::StructSite, interface::String)::Label = Label(span(site.file, children_of(children_of(site.node)[1])[2]), "opts into $interface interface")

"""Finding for struct `site` that misses `gaps` of `interface`; `causes` label code that opts into it; `why` and `fix` explain."""
function gap_finding(site::StructSite, interface::String, gaps::Vector{String}, causes::Vector{Label}, why::String, fix::String)::Finding
    name = definition_name(site.node)
    return Finding(
        NAME, :missing_method, Confidence.definite, "`$(source(site.file, name))` misses $(join(("`$gap`" for gap in gaps), ", ", " and ")) of $interface interface",
        Label(span(site.file, name), "first call to missing method throws"), causes, why, manual_fix(fix),
    )
end

"""Findings for package structs that miss methods of `AbstractArray`, `AbstractString` or iteration interface."""
function findings(facts::FactSet)::Vector{Finding}
    package = facts.package
    isnothing(package) && return Finding[]
    iterators = iterated_types(package)
    found = Finding[]
    for site in package.structs
        type, name = site.type, String(nameof(Base.unwrap_unionall(site.type)))
        if type <: AbstractArray
            gaps = array_gaps(type, name)
            why = "Base array methods call `size` and scalar `getindex`; fallbacks throw"
            isempty(gaps) || push!(found, gap_finding(site, "`AbstractArray`", gaps, [supertype_label(site, "`AbstractArray`")], why, define(gaps)))
        end
        if type <: AbstractString
            gaps = string_gaps(type, name)
            why = "Base string methods call these methods; fallbacks throw `MethodError`"
            isempty(gaps) || push!(found, gap_finding(site, "`AbstractString`", gaps, [supertype_label(site, "`AbstractString`")], why, define(gaps)))
        end
        index = type <: AbstractArray ? nothing : findfirst(((iterated, _),) -> type <: iterated, iterators)
        isnothing(index) && continue
        sized = trait_type(Base.IteratorSize, type)
        gaps = iteration_gaps(type, name, sized)
        isempty(gaps) && continue
        cause = Label(name_span(last(iterators[index])), "`iterate` makes it iterator")
        trait = sized <: Base.HasLength ? "`HasLength`" : sized <: Base.HasShape ? "`HasShape`" : "`HasLength` or `HasShape`"
        why = "`IteratorSize` is $trait, so `collect` calls $(join(("`$gap`" for gap in gaps), " and "))"
        push!(found, gap_finding(site, "iteration", gaps, [cause], why, "$(define(gaps)), or `Base.IteratorSize(::Type{<:$name}) = Base.SizeUnknown()`"))
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.correctness, [92], Stage.package, findings)

end
