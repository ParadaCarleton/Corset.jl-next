"""
`overspecified-type` (F15): argument annotation names specific number type, `AbstractFloat` or concrete container.

## Description
Reports argument annotation of method on public function or constructor of public type when it names, anywhere inside:
- specific number type: `Float64`, `Float32`, `Float16`, `BigFloat`, `Int`, `Int8` to `Int128`, `BigInt`;
- `AbstractFloat`, which rejects rationals and dual numbers;
- concrete container: `Vector`, `Matrix`, `Array`, `Dict`, `Set`.
Union of number types only, as `Union{Int32, Int64}`, reports as whole and widens to `Integer` or `Real`.
Method passes when other method of same function covers its signature: it is fast path beside generic method.
Fix is `likely` when widened method and each other method of function, widened too or not, are disjoint or nested.
Otherwise fix is manual: Julia could find call ambiguous, or drop method with same widened signature.

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

"""Base types rule widens, by type: wider type each becomes, as `WIDER` gives for its name."""
const WIDER_TYPES = IdDict{Any, Type}(first(entry) => getglobal(Base, Symbol(last(entry))) for entry in values(WIDER) if isconcretetype(first(entry)) || first(entry) === AbstractFloat)

"""Concrete containers rule widens, by type name: abstract type of same parameters."""
const CONTAINERS = Dict{Core.TypeName, Type}(Array.body.body.name => AbstractArray, Dict.body.body.name => AbstractDict, Set.body.name => AbstractSet)

"""
Type `type` with every listed type widened, as `widened_text` widens annotation: Base number types, containers, and
upper bounds of `<:` parameters. Changed parameter of invariant type becomes `<:` parameter. Aliases widen too.
"""
function widened_type(@nospecialize(type::Any))::Any
    Base.isvarargtype(type) && return isdefined(type, :N) ? Vararg{widened_type(type.T), type.N} : Vararg{widened_type(type.T)}
    if type isa UnionAll
        variable = TypeVar(type.var.name, type.var.lb, widened_type(type.var.ub))
        return UnionAll(variable, widened_type(type{variable}))
    end
    type isa Union && return Union{widened_type(type.a), widened_type(type.b)}
    type isa DataType || return type
    haskey(WIDER_TYPES, type) && return WIDER_TYPES[type]
    (isempty(type.parameters) || type.name in (Type.body.name, Val.body.name)) && return type
    head = get(CONTAINERS, type.name, type.name.wrapper)
    parameters, variables = Any[], TypeVar[]
    for parameter in type.parameters
        wider = widened_type(parameter)
        if wider === parameter || type.name === Tuple.name
            push!(parameters, wider)
        else
            push!(variables, TypeVar(gensym(:T), wider))
            push!(parameters, last(variables))
        end
    end
    return foldr(UnionAll, variables; init = head{parameters...})
end

"""Signature `signature` with every argument widened; callee and `where` bounds of method stay."""
widened_signature(signature::Type)::Type = Base.rewrap_unionall(Tuple{widened_type.(Base.unwrap_unionall(signature).parameters)...}, signature)

"""Whether `inner` is strict subtype of `outer`: Julia picks method of `inner` for calls both match."""
nested(inner::Type, outer::Type)::Bool = inner <: outer && !(outer <: inner)

"""
Whether method `wide`, widened from `method`, and each other method of its function, before and after its own widening,
are disjoint or nested: no call becomes ambiguous and no method replaces other.
"""
function dispatch_safe(method::Method, wide::Type)::Bool
    callee = Base.unwrap_unionall(method.sig).parameters[1]
    matches = Base._methods_by_ftype(Base.rewrap_unionall(Tuple{callee, Vararg{Any}}, method.sig), -1, Base.get_world_counter())
    for match in matches, other in (match.method.sig, widened_signature(match.method.sig))
        match.method === method || typeintersect(wide, other) === Union{} || nested(wide, other) || nested(other, wide) || return false
    end
    return true
end

"""Whether type `head` takes subtypes in its parameters: `Union` and tuple types."""
covariant(head::Union{Nothing, Type})::Bool = head === Union || (!isnothing(head) && Base.unwrap_unionall(head) <: Tuple)

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

"""
Finding for overspecified `annotation` of `file`, widened to `wider`, with reported parts `found`. Fix is manual unless
widened method is `safe` for dispatch.
"""
function overspecified_finding(file::SyntaxFile, annotation::SyntaxNode, wider::String, found::Vector{SyntaxNode}, safe::Bool)::Finding
    text = source(file, annotation)
    causes = [Label(span(file, part), "names specific type") for part in found if part !== annotation]
    fix = safe ? replace_fix(file, annotation, wider, Tier.likely) : manual_fix("replace with `$wider` after other methods change: widened method overlaps them")
    return Finding(
        NAME, :overspecified, Confidence.definite, "`$text` rejects callers `$wider` accepts", Label(span(file, annotation), "narrower than code needs"),
        causes, "Julia compiles method for each concrete argument type, so wider annotation runs as fast", fix,
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
        safe = nothing
        for argument in parts.arguments, annotation in argument_annotations(argument)
            annotation in seen && continue
            push!(seen, annotation)
            reported = SyntaxNode[]
            wider = widened_text(site.method.module, site.file, annotation, reported)
            isempty(reported) && continue
            isnothing(safe) && (safe = dispatch_safe(site.method, widened_signature(site.method.sig)))
            push!(found, overspecified_finding(site.file, annotation, wider, reported, safe))
        end
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.composability, [15], Stage.package, findings)

end
