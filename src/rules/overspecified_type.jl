"""
`overspecified-type` (F15): argument annotation names specific number type, `AbstractFloat` or concrete container.

## Description
Reports argument annotation of method on public function or constructor of public type when it names, anywhere inside:
- specific number type: `Float64`, `Float32`, `Float16`, `BigFloat`, `Int`, `Int8` to `Int128`, `BigInt`;
- `AbstractFloat`, which rejects rationals and dual numbers;
- concrete container: `Vector`, `Matrix`, `Array`, `Dict`, `Set`.
Union of number types only, as `Union{Int32, Int64}`, reports as whole and widens to `Integer` or `Real`.
Method passes when other method of same function covers its signature: it is fast path beside generic method.

## Rationale
Julia compiles method for each concrete argument type, so wider annotation runs as fast.
Narrow annotation only rejects callers: `Float32`, `Rational`, ForwardDiff `Dual`, views, ranges, GPU arrays.

## Example
```julia
scale(values::Vector{Float64}, factor::Float64)::Vector{Float64} = values .* factor
```

## Alternative
```julia
scale(values::AbstractVector{<:Real}, factor::Real)::AbstractVector{<:Real} = values .* factor
```

## Limitations
Rule reads argument annotations; result types, `where` bounds and struct fields pass.
Private functions pass: no outside caller meets them. Methods on other modules' functions pass: their owner sets signature.
`Bool`, unsigned types and C aliases as `Cint` pass: they mark flags, bit patterns and C calls.
Type alias that names listed type passes.
"""
module OverspecifiedType

using ...Facts

const NAME = Symbol("overspecified-type")

"""Names rule reports: Base type each must resolve to, and wider replacement."""
const WIDER = Dict{String, Tuple{Type, String}}(
    "Float64" => (Float64, "Real"), "Float32" => (Float32, "Real"), "Float16" => (Float16, "Real"), "BigFloat" => (BigFloat, "Real"),
    "AbstractFloat" => (AbstractFloat, "Real"), "Int" => (Int, "Integer"), "Int8" => (Int8, "Integer"), "Int16" => (Int16, "Integer"),
    "Int32" => (Int32, "Integer"), "Int64" => (Int64, "Integer"), "Int128" => (Int128, "Integer"), "BigInt" => (BigInt, "Integer"),
    "Vector" => (Vector, "AbstractVector"), "Matrix" => (Matrix, "AbstractMatrix"), "Array" => (Array, "AbstractArray"),
    "Dict" => (Dict, "AbstractDict"), "Set" => (Set, "AbstractSet"),
)

"""Wider replacement for type name `node` of `file` in `mod`; `nothing` unless it names listed Base type."""
function replacement(mod::Module, file::SyntaxFile, node::SyntaxNode)::Union{Nothing, String}
    entry = get(WIDER, last(split(source(file, node), '.')), nothing)
    return !isnothing(entry) && resolve_type(mod, file, node) === first(entry) ? last(entry) : nothing
end

"""Whether type `head` takes subtypes in its parameters: `Union` and tuple types."""
covariant(head::Union{Nothing, Type})::Bool = head === Union || !isnothing(head) && Base.unwrap_unionall(head) <: Tuple

"""Widened text of curly `node`: union of number types becomes its join; parameters widen, with `<:` inside invariant type."""
function widened_curly(mod::Module, file::SyntaxFile, node::SyntaxNode, found::Vector{SyntaxNode})::String
    head, parameters = children_of(node)[1], children_of(node)[2:end]
    resolved = resolve_type(mod, file, head)
    resolved in (Type, Val) && return source(file, node)
    wider = [replacement(mod, file, parameter) for parameter in parameters]
    if resolved === Union && all(!isnothing, wider) && all(in(("Real", "Integer")), wider)
        push!(found, node)
        return all(==("Integer"), wider) ? "Integer" : "Real"
    end
    texts = String[]
    for parameter in parameters
        before = length(found)
        text = widened_text(mod, file, parameter, found)
        changed = length(found) > before && !covariant(resolved) && kind_name(parameter) != "<:"
        push!(texts, changed ? "<:$text" : text)
    end
    return "$(widened_text(mod, file, head, found)){$(join(texts, ", "))}"
end

"""Widened text of annotation `node` of `file` in `mod`; pushes each reported part to `found`."""
function widened_text(mod::Module, file::SyntaxFile, node::SyntaxNode, found::Vector{SyntaxNode})::String
    kind = kind_name(node)
    kind == "curly" && return widened_curly(mod, file, node, found)
    kind == "<:" && length(children_of(node)) == 1 && return "<:" * widened_text(mod, file, only(children_of(node)), found)
    wider = replacement(mod, file, node)
    isnothing(wider) && return source(file, node)
    push!(found, node)
    return wider
end

"""Whether `public` values hold function `method` belongs to, or type it constructs, by type name in `types`."""
function public_function(method::Method, public::Base.IdSet{Any}, types::Set{Core.TypeName})::Bool
    callee = Base.unwrap_unionall(method.sig).parameters[1]
    Base.isType(callee) || return isdefined(callee, :instance) && callee.instance in public
    target = Base.unwrap_unionall(callee.parameters[1])
    return target isa DataType && target.name in types
end

"""Whether wider method in `sites` covers `site`: `site` is fast path beside generic method of same function."""
fast_path(site::MethodSite, sites::Vector{MethodSite})::Bool =
    any(other -> site.method.sig <: other.method.sig && !(other.method.sig <: site.method.sig), sites)

"""Finding for overspecified `annotation` of `file`, widened to `wider`, with reported parts `found`."""
function overspecified_finding(file::SyntaxFile, annotation::SyntaxNode, wider::String, found::Vector{SyntaxNode})::Finding
    text = source(file, annotation)
    causes = [Label(span(file, part), "names specific type") for part in found if part !== annotation]
    return Finding(
        NAME, :overspecified, Confidence.definite, "`$text` rejects callers `$wider` accepts", Label(span(file, annotation), "narrower than code needs"),
        causes, "Julia compiles method for each concrete argument type, so wider annotation runs as fast", replace_fix(file, annotation, wider, Tier.likely),
    )
end

"""Findings for overspecified argument annotations of package methods on public functions; fast paths pass."""
function findings(facts::FactSet)::Vector{Finding}
    package = facts.package
    isnothing(package) && return Finding[]
    types = Set{Core.TypeName}(body.name for body in map(Base.unwrap_unionall, collect(package.public)) if body isa DataType)
    # Default arguments give one definition several methods; each annotation reports once.
    seen = Base.IdSet{SyntaxNode}()
    found = Finding[]
    for site in package.methods
        parts = isnothing(site.node) ? nothing : signature(site.node)
        (isnothing(parts) || !public_function(site.method, package.public, types) || fast_path(site, package.methods)) && continue
        for argument in children_of(first(parts))[2:end], annotation in argument_annotations(argument)
            annotation in seen && continue
            push!(seen, annotation)
            reported = SyntaxNode[]
            wider = widened_text(site.method.module, site.file, annotation, reported)
            isempty(reported) || push!(found, overspecified_finding(site.file, annotation, wider, reported))
        end
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.composability, [15], Stage.package, findings)

end
