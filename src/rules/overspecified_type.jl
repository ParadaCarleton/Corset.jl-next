"""
`overspecified-type` (F15): argument annotation names specific number type, `AbstractFloat` or concrete container.

## Description
Reports argument annotation of package function or constructor of package type, private included, when it names,
anywhere inside:
- specific number type: `Float64`, `Float32`, `Float16`, `BigFloat`, `Int`, `Int8` to `Int128`, `BigInt`;
- `AbstractFloat`, which rejects rationals and dual numbers;
- concrete container: `Vector`, `Matrix`, `Array`, `Dict`, `Set`.
Union of number types only, as `Union{Int32, Int64}`, reports as whole and widens to `Integer` or `Real`.
Private method counts: public `f(x) = _f(x)` with `_f(x::Vector)` rejects every other vector.
Method passes when other method of same function covers its signature: it is fast path beside generic method.
Fix is `likely` when method as fix widens it and each other method of function, before and after own fix, are disjoint
or nested.
Otherwise fix is manual: Julia could find call ambiguous, or drop method with same widened signature.
Fix is manual for function or callable object package code tests for methods: passes to `applicable`, `hasmethod`,
`which` or `methods`, or calls in `try` whose handler can swallow `MethodError`, directly or through package method.
Widening changes what that code does.
Argument that body resizes (`push!`, `d[k] = v`) widens too: view or range there throws `MethodError`, as in Base
`append!(a::AbstractVector, items)`. Argument stored into struct field passes when its widened type does not fit field
type, since `new` converts it to copy; number field converts by value. Uses count through local, `for` loop, closure
capture, keyword call and package callee whose parameter type can take argument (`PackageFacts.uses`).

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
Methods on other modules' functions and constructors of other modules' types pass: their owner sets signature.
Fix stays `likely` when package code tests for methods in closure, keyword body or generated code, through keyword
or splatted argument, or by `try` around caller: rule follows positional arguments and calls directly inside `try` only.
`Bool`, unsigned types and C aliases as `Cint` pass: they mark flags, bit patterns and C calls.
Type alias that names listed type passes.
Rule sees uses of positional arguments only: store of keyword argument into struct field gets fix.
Fix widens written container and its element type: caller with view, range, static array or narrower element type
gets run-time error at write.
Fix is manual when widened annotation holds call or interpolation: rule cannot build fixed signature to check dispatch.
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
Type `type` with every listed type widened, as `widened_text!` widens annotation: Base number types, containers, and
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

"""
Value annotation text `expression` names in `mod` with method type `variables` in scope: name, dotted name, curly type
with `<:` parameters, `where` with plain or `<:` variables, integer and symbol literals. `nothing` for other syntax:
rule runs no code of package.
"""
function annotation_value(mod::Module, expression::Any, variables::AbstractDict{Symbol, TypeVar})::Union{Nothing, Some{Any}}
    expression isa Symbol && return haskey(variables, expression) ? Some{Any}(variables[expression]) : global_value(mod, expression)
    expression isa Integer && return Some{Any}(expression)
    expression isa QuoteNode && return Some{Any}(expression.value)
    if Meta.isexpr(expression, :., 2)
        owner = something(annotation_value(mod, expression.args[1], variables), Some{Any}(nothing))
        return owner isa Module ? global_value(owner, (expression.args[2]::QuoteNode).value::Symbol) : nothing
    end
    Meta.isexpr(expression, :curly) && return curly_value(mod, expression.args, variables)
    Meta.isexpr(expression, :where) && return where_value(mod, expression, variables)
    return nothing
end

"""
Value of constant global `name` in `mod`. `nothing` when `mod` has no such binding (`baremodule` without
`AbstractVector`), or binding is not constant: method signature holds its value at definition, not current one.
"""
global_value(mod::Module, name::Symbol)::Union{Nothing, Some{Any}} = isdefinedglobal(mod, name) && isconst(mod, name) ? Some{Any}(getglobal(mod, name)) : nothing

"""Whether `value` can bound type variable."""
bound_value(value::Any)::Bool = value isa Union{Type, TypeVar}

"""Value of curly type: head `arguments[1]` applied to the rest; each `<:` parameter becomes new variable."""
function curly_value(mod::Module, arguments::AbstractVector, variables::AbstractDict{Symbol, TypeVar})::Union{Nothing, Some{Any}}
    values, bound = Any[], TypeVar[]
    for argument in arguments
        upper = Meta.isexpr(argument, :<:, 1)
        found = annotation_value(mod, upper ? only(argument.args) : argument, variables)
        # Name that holds no type (`const Real = 1`) cannot bound variable.
        (isnothing(found) || (upper && !bound_value(something(found)))) && return nothing
        upper && push!(bound, TypeVar(gensym(:T), something(found)))
        push!(values, upper ? last(bound) : something(found))
    end
    applied = try
        Core.apply_type(values...)
    catch error
        # Julia rejects head or parameters (`Vector{Int, 2}`, head `1`): fixed signature unknown.
        error isa Union{TypeError, ErrorException} || rethrow()
        return nothing
    end
    return Some{Any}(foldr(UnionAll, bound; init = applied))
end

"""Value of `where` type `expression`: body with each declaration, `T` or `T <: Bound`, as new variable."""
function where_value(mod::Module, expression::Expr, variables::AbstractDict{Symbol, TypeVar})::Union{Nothing, Some{Any}}
    inner, bound = Dict{Symbol, TypeVar}(variables), TypeVar[]
    for declaration in expression.args[2:end]
        plain = declaration isa Symbol
        # Other declaration (`T >: Bound`, `A <: T <: B`) leaves value unknown.
        (plain || (Meta.isexpr(declaration, :<:, 2) && declaration.args[1] isa Symbol)) || return nothing
        name, upper = plain ? (declaration, Some{Any}(Any)) : (declaration.args[1]::Symbol, annotation_value(mod, declaration.args[2], inner))
        (isnothing(upper) || !bound_value(something(upper))) && return nothing
        push!(bound, TypeVar(name, something(upper)))
        inner[name] = last(bound)
    end
    body = annotation_value(mod, expression.args[1], inner)
    return isnothing(body) || !(something(body) isa Type) ? nothing : Some{Any}(foldr(UnionAll, bound; init = something(body)))
end

"""Type variables of method signature `signature` by name."""
function method_variables(signature::Type)::Dict{Symbol, TypeVar}
    variables = Dict{Symbol, TypeVar}()
    while signature isa UnionAll
        variables[signature.var.name] = signature.var
        signature = signature.body
    end
    return variables
end

"""Whether `inner` is strict subtype of `outer`: Julia picks method of `inner` for calls both match."""
nested(inner::Type, outer::Type)::Bool = inner <: outer && !(outer <: inner)

"""Fix of positional argument: its position and parameter type of fixed signature."""
const Edit = Pair{Int, Any}

"""Signature `signature` with each of `edits` applied."""
function edited(signature::Type, edits::AbstractVector{Edit})::Type
    parameters = Any[tuple_parameters(signature)...]
    for (position, type) in edits
        parameters[position + 1] = type
    end
    return Base.rewrap_unionall(Tuple{parameters...}, signature)
end

"""Every subset of `edits`, empty and full included."""
function subsets(edits::AbstractVector{Edit})::Vector{Vector{Edit}}
    chosen = [Edit[]]
    # Each edit doubles subsets: those without it, and same ones with it.
    for edit in edits
        append!(chosen, [Edit[subset; edit] for subset in chosen])
    end
    return chosen
end

"""Most fixes of two methods whose combinations rule checks: 2^10 signature pairs."""
const COMBINATION_LIMIT = 10

"""
Whether `edit` of `method` keeps dispatch beside each other method of its function, under every combination of other
fixes of both (`edits`; method without entry has none): signatures stay disjoint or nested, so no call becomes ambiguous
and no method replaces other. Other method whose fixes are unknown (`nothing`) fails; `nothing` past `COMBINATION_LIMIT`.
"""
function dispatch_safe(method::Method, edit::Edit, edits::IdDict{Method, <:Union{Nothing, AbstractVector{Edit}}})::Union{Nothing, Bool}
    own = Edit[other for other in something(edits[method]) if first(other) != first(edit)]
    callee = tuple_parameters(method.sig)[1]
    matches = Base._methods_by_ftype(Base.rewrap_unionall(Tuple{callee, Vararg{Any}}, method.sig), -1, Base.get_world_counter())
    for match in matches
        match.method === method && continue
        theirs = get(edits, match.method, Edit[])
        isnothing(theirs) && return false
        length(own) + length(theirs) > COMBINATION_LIMIT && return nothing
        for mine in subsets(own), others in subsets(theirs)
            wide, other = edited(method.sig, Edit[edit; mine]), edited(match.method.sig, others)
            typeintersect(wide, other) === Union{} || nested(wide, other) || nested(other, wide) || return false
        end
    end
    return true
end

"""Whether type `head` takes subtypes in its parameters: `Union` and tuple types."""
covariant(head::Union{Nothing, Type})::Bool = head === Union || (!isnothing(head) && Base.unwrap_unionall(head) <: Tuple)

"""Widened text of curly `node`: union of number types becomes its join; parameters widen, with `<:` inside invariant type."""
function widened_curly!(found::AbstractVector{SyntaxNode}, mod::Module, file::SyntaxFile, node::SyntaxNode)::String
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
        text = widened_text!(found, mod, file, parameter)
        changed = length(found) > before && !covariant(resolved) && kind_name(parameter) != "<:"
        push!(texts, changed ? "<:$text" : text)
    end
    return "$(widened_text!(found, mod, file, head)){$(join(texts, ", "))}"
end

"""Widened text of annotation `node` of `file` in `mod`; pushes each reported part to `found`."""
function widened_text!(found::AbstractVector{SyntaxNode}, mod::Module, file::SyntaxFile, node::SyntaxNode)::String
    kind = kind_name(node)
    kind == "curly" && return widened_curly!(found, mod, file, node)
    kind == "<:" && length(children_of(node)) == 1 && return "<:" * widened_text!(found, mod, file, only(children_of(node)))
    wider = replacement(mod, file, node)
    isnothing(wider) && return source(file, node)
    push!(found, node)
    return wider
end

"""Whether package `modules` own function or callable type `method` belongs to, or type it constructs."""
function owned(method::Method, modules::AbstractSet{Module})::Bool
    callee = Base.unwrap_unionall(tuple_parameters(method.sig)[1])
    Base.isType(callee) && (callee = Base.unwrap_unionall(callee.parameters[1]))
    return callee isa DataType && callee.name.module in modules
end

"""Whether `method` belongs to function, type or callable object of `probed`, which package code tests for methods."""
function probed_callee(method::Method, probed::AbstractSet)::Bool
    callee = Base.rewrap_unionall(tuple_parameters(method.sig)[1], method.sig)
    # Loop, since closure over type value compiles once per type.
    for tested in probed
        tested isa callee && return true
    end
    return false
end

"""
What to do before fix `edit` of `method`; `nothing` when fix is safe. Fix of keyword, or of position method lacks, is
`nothing` edit: signature stays. `edits` holds fixes of each package method, `nothing` when rule cannot build them;
package code tests functions of `probed` for methods.
"""
function fix_blocker(method::Method, edit::Union{Nothing, Edit}, edits::IdDict{Method, <:Union{Nothing, AbstractVector{Edit}}}, probed::AbstractSet)::Union{Nothing, String}
    isnothing(edits[method]) && return "checking other methods of function: Corset cannot build widened signature"
    safe = isnothing(edit) || dispatch_safe(method, edit, edits)
    isnothing(safe) && return "checking other methods of function: too many fixes to check each combination"
    safe || return "other methods change: widened method overlaps them"
    probed_callee(method, probed) && return "checking `applicable` calls and `MethodError` catches: widening changes what they do"
    return nothing
end

"""Uses of argument without need."""
const NO_USES = Dict{Int, ArgumentUse}()

"""
Whether argument at `position` over `methods` of one definition with `count` positional arguments goes into struct field
its widened type does not fit (`PackageFacts.uses`); number field converts by value, so it fits. Keyword body has more
arguments than source, at other positions: it passes.
"""
function narrow_store(uses::IdDict{Method, <:AbstractDict{<:Integer, ArgumentUse}}, methods::AbstractVector{Method}, position::Integer, count::Integer)::Bool
    for method in methods
        position <= method.nargs - 1 <= count || continue
        use = get(get(uses, method, NO_USES), position, nothing)
        isnothing(use) && continue
        wide = widened_type(Facts.argument_type(method, position))
        any(field -> !(wide <: field || field <: Number), use.stored) && return true
    end
    return false
end

"""Whether wider method in `sites` covers `site`: `site` is fast path beside generic method of same function."""
fast_path(site::MethodSite, sites::AbstractVector{MethodSite})::Bool =
    any(other -> site.method.sig <: other.method.sig && !(other.method.sig <: site.method.sig), sites)

"""
Finding for overspecified `annotation` of `file`, widened to `wider`, with reported parts `found`. Fix is manual with
`blocker`, what to do first; else `likely`.
"""
function overspecified_finding(file::SyntaxFile, annotation::SyntaxNode, wider::String, found::AbstractVector{SyntaxNode}, blocker::Union{Nothing, String})::Finding
    text = source(file, annotation)
    causes = [Label(span(file, part), "names specific type") for part in found if part !== annotation]
    fix = isnothing(blocker) ? replace_fix(file, annotation, wider, Tier.likely) : manual_fix("replace with `$wider` after $blocker")
    return Finding(
        NAME, :overspecified, Confidence.definite, "`$text` rejects callers `$wider` accepts", Label(span(file, annotation), "narrower than code needs"),
        causes, "Julia compiles method for each concrete argument type, so wider annotation runs as fast", fix,
    )
end

"""Overspecified annotation of `file`: widened text, reported parts, and each method of its definition with fix there."""
struct Report
    file::SyntaxFile
    wider::String
    reported::Vector{SyntaxNode}
    sites::Vector{Tuple{Method, Union{Nothing, Edit}}}
end

"""Findings for overspecified argument annotations of package methods on package functions; fast paths pass."""
function findings(facts::FactSet)::Vector{Finding}
    package = facts.package
    isnothing(package) && return Finding[]
    modules = Set(package.modules)
    # Default arguments give one definition several methods; each annotation reports once, with uses of all.
    definitions = IdDict{SyntaxNode, Vector{Method}}()
    foreach(site -> isnothing(site.node) || push!(get!(Vector{Method}, definitions, site.node), site.method), package.methods)
    # Fixes of every method come first: blocker of one method needs fixes of others.
    edits, reports, order = IdDict{Method, Union{Nothing, Vector{Edit}}}(), IdDict{SyntaxNode, Report}(), SyntaxNode[]
    for site in package.methods
        parts = isnothing(site.node) ? nothing : signature(site.node)
        (isnothing(parts) || !owned(site.method, modules) || fast_path(site, package.methods)) && continue
        # Fixed signature takes widened text of each annotation, as fix writes it: aliases and other text stay.
        own, variables, typed = Edit[], method_variables(site.method.sig), true
        parameter_count = length(tuple_parameters(site.method.sig))
        positional = count(argument -> kind_name(argument) != "parameters", parts.arguments)
        position = 0
        for argument in parts.arguments
            keyword = kind_name(argument) == "parameters"
            keyword || (position += 1)
            (keyword || !narrow_store(package.uses, definitions[site.node], position, positional)) || continue
            for annotation in argument_annotations(argument)
                reported = SyntaxNode[]
                wider = widened_text!(reported, site.method.module, site.file, annotation)
                isempty(reported) && continue
                # Fix must name type (`const Integer = 1` breaks it), keyword too; default-argument method lacks later positions.
                value = annotation_value(site.method.module, Meta.parse(wider), variables)
                type = isnothing(value) || !bound_value(something(value)) ? nothing : something(value)
                typed &= !isnothing(type)
                splat = kind_name(argument) == "..."
                edit = !isnothing(type) && !keyword && position < parameter_count ? Edit(position, splat ? Vararg{type} : type) : nothing
                isnothing(edit) || push!(own, edit)
                report = get!(() -> (push!(order, annotation); Report(site.file, wider, reported, Tuple{Method, Union{Nothing, Edit}}[])), reports, annotation)
                push!(report.sites, (site.method, edit))
            end
        end
        edits[site.method] = typed ? own : nothing
    end
    found = Finding[]
    for annotation in order
        report, blocker = reports[annotation], nothing
        # Fix applies to every method of definition: first blocker of any decides.
        for (method, edit) in report.sites
            blocker = fix_blocker(method, edit, edits, package.probed)
            isnothing(blocker) || break
        end
        push!(found, overspecified_finding(report.file, annotation, report.wider, report.reported, blocker))
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.composability, [15], Stage.package, findings)

end
