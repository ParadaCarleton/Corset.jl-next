# The `no-default` rule: names a project lists (`Repository.no_default_names`) never take a default value.

"""The names that carry a default in call or struct-field syntax `node`: `a = 1` (a `kw`), `a::T = 1` and `a::T = 1` after `;`."""
function defaulted_name(node::Any)::Symbol
    if Meta.isexpr(node, :kw) || Meta.isexpr(node, :(=))
        return get(bound_names(first(node.args)), 1, NO_NAME)
    end
    return NO_NAME
end

"""The names with a default among the arguments of method signature `call`, keywords after `;` included."""
function defaulted_arguments(call::Expr)::Vector{Symbol}
    arguments = call.args[2:end]
    for argument in arguments
        if Meta.isexpr(argument, :parameters)
            append!(arguments, argument.args)
        end
    end
    return filter(!=(NO_NAME), defaulted_name.(arguments))
end

"""The names with a default value among the fields of struct `node`: `@kwdef`-style `a::Int = 1`."""
defaulted_fields(node::Expr)::Vector{Symbol} = filter(!=(NO_NAME), defaulted_name.(last(node.args).args))

"""One site per default on a name of `repository.no_default_names`, keyed by file and enclosing function, at the defining line."""
function default_sites(repository::Repository, source::Source)::Vector{Site}
    return [
        Site("$(source.name) $(item.enclosing)", source.path, item.line, "`$name` takes a default; make the caller pass it")
            for item in source.located
            for name in defaults_in(item.node) if name in repository.no_default_names
    ]
end

"""The names parsed expression `node` gives a default: a method signature's arguments, or a struct's fields."""
function defaults_in(node::Expr)::Vector{Symbol}
    call = signature_call(node)
    if !isnothing(call)
        return defaulted_arguments(call)
    end
    return node.head === :struct ? defaulted_fields(node) : Symbol[]
end
