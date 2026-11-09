# The rules `concrete-annotation` and `any-supertype`: every type annotation is generic (an abstract type
# or a type parameter), and every struct declares an abstract supertype. See `docs/src/rules.md`.

# Heads whose parameters are covariant, so each parameter is itself an annotation.
const COVARIANT_HEADS = (:Union, :Tuple, :NTuple, :Vararg, :Type)

"""The type that parsed name `annotation` refers to in `scope` or Base, or `nothing` for a type variable, a name that resolves to no type, or an unresolved name."""
function lookup_type(annotation::Symbol, scope::Module, variables::AbstractVector{Symbol})::Union{Type, Nothing}
    if annotation in variables
        return nothing
    end
    for source in (scope, Base)
        if isdefined(source, annotation)
            named = getglobal(source, annotation)
            return named isa Type ? named : nothing
        end
    end
    return nothing
end

function lookup_type(annotation::Expr, scope::Module, variables::AbstractVector{Symbol})::Union{Type, Nothing} # lint: unstable-variable  Expr nodes hold untyped arguments
    if !(last(annotation.args) isa QuoteNode)
        return nothing
    end
    owner = first(annotation.args)
    parent = owner isa Symbol && isdefined(scope, owner) ? getglobal(scope, owner) : nothing
    field = last(annotation.args).value
    return parent isa Module && isdefined(parent, field) && getglobal(parent, field) isa Type ? getglobal(parent, field) : nothing
end

"""Whether `named` needs no generic form: `Bool`, an `Enum` type, or a type whose direct supertype is `Any` (`Nothing`, `Symbol`, `Missing`, tuples)."""
function exempt_type(named::Type)::Bool
    plain = Base.unwrap_unionall(named)
    return named === Bool || named <: Enum || (plain isa DataType && supertype(plain) === Any)
end

"""Whether `named` is a concrete type with an abstract parent to name instead."""
function concrete_type(named::Type)::Bool
    plain = Base.unwrap_unionall(named)
    return plain isa DataType && !isabstracttype(plain) && !exempt_type(named)
end

"""
    annotation_problems(annotation, scope, variables, allowed)

Why parsed type expression `annotation` is not generic, one sentence each, empty when it is. `variables` are
the type variables in scope; a concrete head in `allowed` is accepted. A concrete name, a bare `Type` or `Vararg`,
and a type argument that fixes an invariant parameter (`AbstractVector{Float64}`, `AbstractVector{Real}`; write
`AbstractVector{<:Real}`) are problems.
"""
function annotation_problems(annotation::Symbol, scope::Module, variables::AbstractVector{Symbol}, allowed::Tuple{Vararg{Symbol}})::Vector{String}
    if annotation === :Type
        return ["bare `Type` is not specialized on; write `Type{T}`"]
    elseif annotation === :Vararg
        return ["bare `Vararg` is not specialized on; write `Vararg{T, N}`"]
    end
    named = lookup_type(annotation, scope, variables)
    return isnothing(named) || annotation in allowed || !concrete_type(named) ? String[] : ["`$annotation` is concrete; name an abstract type or a type variable"]
end

function annotation_problems(annotation::Expr, scope::Module, variables::AbstractVector{Symbol}, allowed::Tuple{Vararg{Symbol}})::Vector{String} # lint: unstable-variable  Expr nodes hold untyped arguments
    if annotation.head === :.
        named = lookup_type(annotation, scope, variables)
        return isnothing(named) || !concrete_type(named) ? String[] : ["`$annotation` is concrete; name an abstract type or a type variable"]
    elseif annotation.head !== :curly
        return String[]
    end
    head, parameters = Iterators.peel(annotation.args)
    if head in COVARIANT_HEADS
        return collect(String, Iterators.flatten(annotation_problems.(parameters, (scope,), (variables,), (allowed,))))
    end
    return [annotation_problems(head, scope, variables, allowed); collect(String, Iterators.flatten(parameter_problems.(parameters, (scope,), (variables,))))]
end

annotation_problems(::Any, ::Module, ::AbstractVector{Symbol}, ::Tuple{Vararg{Symbol}})::Vector{String} = String[]

"""Why parsed type argument `parameter` of an invariant type fixes the parameter exactly, empty when it is a type variable, a `<:` bound that is generic, or a value."""
function parameter_problems(parameter::Symbol, scope::Module, variables::AbstractVector{Symbol})::Vector{String}
    named = lookup_type(parameter, scope, variables)
    return isnothing(named) || exempt_type(named) ? String[] : ["type argument `$parameter` fixes the parameter exactly; write `<:$parameter` or a type variable"]
end

function parameter_problems(parameter::Expr, scope::Module, variables::AbstractVector{Symbol})::Vector{String} # lint: unstable-variable  Expr nodes hold untyped arguments
    if parameter.head === :<:
        return annotation_problems(last(parameter.args), scope, variables, ())
    elseif parameter.head === :curly
        return ["type argument `$parameter` fixes the parameter exactly; write `<:` of a generic type or a type variable"]
    end
    return String[]
end

parameter_problems(::Any, ::Module, ::AbstractVector{Symbol})::Vector{String} = String[]

"""Whether parsed `node` calls the variable `name` (`name(…)` or `name.(…)`)."""
function calls_variable(node::Expr, name::Symbol)::Bool # lint: unstable-variable  Expr nodes hold untyped arguments
    if node.head in (:call, :.) && first(node.args) === name
        return true
    end
    for argument in node.args
        if argument isa Expr && calls_variable(argument, name)
            return true
        end
    end
    return false
end
calls_variable(::Any, ::Symbol)::Bool = false

"""Why argument `name` annotated `annotation` of a method with `body` is not generic: `annotation_problems`, and a `Function` the body only passes through."""
function argument_problems(name::Symbol, annotation::Any, body::Any, scope::Module, variables::AbstractVector{Symbol})::Vector{String} # lint: unstable-variable  Expr nodes hold untyped arguments
    if annotation === :Function && !calls_variable(body, name)
        return ["`Function` argument `$name` is passed through unspecialized; annotate it with a type variable (`f::F`)"]
    end
    allowed = resizes(body, name) ? CONCRETE_CONTAINERS : ()
    return annotation_problems(annotation, scope, variables, allowed)
end

"""The upper bounds of the `where` clauses of parsed function definition `node` (`Real` of `T <: Real`)."""
function where_bounds(node::Expr)::Vector{Any}
    bounds = Any[]
    signature = node.args[1]
    while signature isa Expr && signature.head in (:where, :(::))
        if signature.head === :where
            append!(bounds, entry.args[2] for entry in signature.args[2:end] if entry isa Expr && entry.head === :<: && length(entry.args) == 2)
        end
        signature = signature.args[1]
    end
    return bounds
end

"""Why the arguments, `where` bounds and result type of parsed function definition `node` are not generic; empty for anything but a method definition."""
function definition_problems(node::Expr, scope::Module)::Vector{String}
    call = signature_call(node)
    if isnothing(call) || length(node.args) < 2
        return String[]
    end
    variables = where_variables(node)
    problems = String[]
    for argument in call.args[2:end], (name, annotation) in annotated_arguments(argument)
        append!(problems, argument_problems(name, annotation, node.args[2], scope, variables))
    end
    for bound in where_bounds(node)
        append!(problems, annotation_problems(bound, scope, variables, ()))
    end
    if !constructs_own_type(node)
        append!(problems, annotation_problems(return_annotation(node), scope, variables, ()))
    end
    return problems
end

"""The sites of the Julia file `source` whose methods and public structs annotate a concrete type, one per problem, keyed by file; names resolve in `scope`."""
function concrete_annotations(source::Source, scope::Module)::Vector{Site}
    sites = Site[]
    for item in source.located
        problems = definition_problems(item.node, scope)
        span = isempty(problems) ? (0:0) : definition_lines(item.node, item.line)
        for problem in problems
            push!(sites, Site(source.name, source.path, first(span), last(span), problem))
        end
    end
    for node in struct_nodes(source.tree), problem in field_problems(Expr(node), scope)
        push!(sites, Site(source.name, source.path, first(SYNTAX.source_location(node)), problem))
    end
    return sites
end

"""The `struct` syntax nodes at or below `node`."""
function struct_nodes(node::SYNTAX.SyntaxNode)::Vector{SYNTAX.SyntaxNode}
    nested = SYNTAX.SyntaxNode[found for child in node_children(node) for found in struct_nodes(child)]
    return SYNTAX.kind(node) === STRUCT_KIND ? vcat([node], nested) : nested
end

"""The name, type-parameter names and declared supertype (`nothing` when none) of parsed `struct` header `header`."""
function struct_header(header::Any)::Tuple{Symbol, Vector{Symbol}, Any} # lint: unstable-variable  Expr nodes hold untyped arguments
    declared = nothing
    if Meta.isexpr(header, :<:)
        header, declared = header.args
    end
    if Meta.isexpr(header, :curly)
        return first(header.args), bound_name.(header.args[2:end]), declared
    end
    return header, Symbol[], declared
end

"""The field declarations of parsed struct `body`, each as an `x::T` expression; fields without a type are left out."""
function typed_fields(body::Expr)::Vector{Expr} # lint: unstable-variable  Expr nodes hold untyped arguments
    unwrapped = [Meta.isexpr(field, :const) ? first(field.args) : field for field in body.args]
    return Expr[field for field in unwrapped if Meta.isexpr(field, :(::)) && length(field.args) == 2]
end

"""Whether parsed type expression `declared` of a field is a type variable of the struct, a type built only from them and values, or a type with no abstract parent."""
function parameter_built(declared::Any, scope::Module, variables::AbstractVector{Symbol})::Bool # lint: unstable-variable  Expr nodes hold untyped arguments
    if declared isa Symbol
        named = lookup_type(declared, scope, variables)
        return declared in variables || (!isnothing(named) && exempt_type(named))
    elseif Meta.isexpr(declared, :curly)
        return all(parameter -> parameter_built(parameter, scope, variables), Iterators.drop(declared.args, 1))
    end
    return !(declared isa Expr)
end

"""Why the fields of the parsed `struct` expression `declaration` are not type parameters: a concrete or abstract field type in a struct that `scope` exports or declares public."""
function field_problems(declaration::Expr, scope::Module)::Vector{String} # lint: unstable-variable  Expr nodes hold untyped arguments
    name, variables, _ = struct_header(declaration.args[2])
    if !(name isa Symbol) || !isdefined(scope, name) || !Base.ispublic(scope, name)
        return String[]
    end
    fields = [field for field in typed_fields(declaration.args[3]) if !parameter_built(last(field.args), scope, variables)]
    return ["field `$field` of public struct `$name` must be a type parameter" for field in fields]
end

"""The sites of the structs of `source` that declare no supertype, or `Any`: a later type cannot extend one."""
function any_supertype_sites(source::Source)::Vector{Site}
    sites = Site[]
    for node in struct_nodes(source.tree)
        name, _, declared = struct_header(Expr(node).args[2])
        if isnothing(declared) || declared === :Any
            push!(sites, Site(source.name, source.path, first(SYNTAX.source_location(node)), "struct `$name` has supertype `Any`; declare an abstract supertype"))
        end
    end
    return sites
end
