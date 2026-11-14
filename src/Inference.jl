"""
`inference` stage: infer package methods on stand-in signatures (`Signatures`); map typed statements to source spans.

Inference runs on unoptimized code, since TypedSyntax.jl maps unoptimized statements to nodes of `syntax` stage tree.
Method with untyped argument is inferred only where inferred package code calls it with stand-in types.
"""
module Inference

using TypedSyntax: TypedSyntax
using ..Facts: Facts, PackageFacts, InferenceFacts, TypedCode, MethodSite, SyntaxFile, SyntaxNode, Span, Precision, BlindSpot
using ..Facts: children_of, kind_name, identifier_name, source, signature, callee_node, call_arguments
using ..Package: Package
using ..StandIns: StandIns
using ..Signatures: LIMIT, method_signatures, struct_stand_ins

const CC = Core.Compiler

"""Callees lowering inserts, so source need not spell them; callee check passes their nodes unchecked."""
const LOWERED = Set(
    [
        :getindex, :setindex!, :iterate, :indexed_iterate, :convert, :getproperty, :setproperty!, :typeassert, :isa,
        :(===), :not_int, :broadcasted, :materialize, :materialize!, :Generator, :tuple, :apply_type, :kwcall, :getfield,
        :isdefined, :_apply_iterate, :vect, :hcat, :vcat, :hvcat, :typed_vcat, :typed_hcat, :(:), :maybeview, :view,
        :dotview, :firstindex, :lastindex, :kwerr, :keys, :diff_names, :isempty, :_typeof_captured_variable, :fieldtype,
        :throw, :string, :cconvert, :unsafe_convert, :_expr, :merge, :structdiff, :pairs, :NamedTuple, :ifelse, :literal_pow,
    ]
)

"""Whether positional argument `node` binds name without type: `x`, `x = 1`, `xs...`, `(a, b)`; `_` binds nothing."""
function untyped_argument(node::SyntaxNode)::Bool
    while kind_name(node) in ("=", "kw", "...")
        node = children_of(node)[1]
    end
    return kind_name(node) == "tuple" || (kind_name(node) == "Identifier" && identifier_name(node) != "_")
end

"""
Whether method of `site` has positional argument without type in source. Explicit `::Any` opts out on purpose, so it
counts as typed. Site without definition node counts as typed. Package stage leaves out keyword bodies.
"""
function untyped(site::MethodSite)::Bool
    parts = isnothing(site.node) ? nothing : signature(site.node)
    isnothing(parts) && return false
    # Keyword group comes last, and method for omitted default values declares fewer arguments, so slice leaves out both.
    return any(untyped_argument, parts.arguments[1:(length(Base.unwrap_unionall(site.method.sig).parameters) - 1)])
end

"""Unoptimized typed code of `method` on `signature`, its method instance and result type; `nothing` when inference gives none."""
function infer(method::Method, signature::Type)::Union{Nothing, Tuple{Core.MethodInstance, Core.CodeInfo, Type}}
    intersection, environment = ccall(:jl_type_intersection_with_env, Any, (Any, Any), signature, method.sig)::Core.SimpleVector
    instance = CC.specialize_method(method, intersection, environment)
    frame = CC.typeinf_frame(CC.NativeInterpreter(), instance, false)
    return isnothing(frame) ? nothing : (instance, frame.src, CC.widenconst(CC.ignorelimited(frame.result.result)))
end

"""Call expression of `statement`, through slot assignment (`_4 = f(x)`); `nothing` for other statement."""
function statement_call(statement::Any)::Union{Nothing, Expr}
    statement isa Expr && statement.head === :(=) && (statement = statement.args[2])
    return statement isa Expr && statement.head === :call ? statement : nothing
end

"""Name of function `call` calls: global, or global earlier statement reads; `nothing` for computed callee."""
function callee_name(code::Core.CodeInfo, call::Expr)::Union{Nothing, Symbol}
    callee = call.args[1]
    callee isa Core.SSAValue && (callee = code.code[callee.id])
    return callee isa GlobalRef ? callee.name : nothing
end

"""Whether `node` spells call to `name` with `arguments` positional arguments; callee lowering inserts passes."""
function spells(file::SyntaxFile, node::SyntaxNode, name::Symbol, arguments::Int)::Bool
    name in LOWERED && return true
    kind_name(node) == "call" || return false
    positional = count(part -> kind_name(part) != "parameters", call_arguments(node))
    return positional == arguments && Package.unqualified(source(file, callee_node(node))) == string(name)
end

"""Syntax nodes TypedSyntax.jl maps each statement of `code` to; none for generated function output or site without definition node."""
function mappings(code::Core.CodeInfo, instance::Core.MethodInstance, site::MethodSite)::Vector{Vector{SyntaxNode}}
    (isnothing(site.node) || Base.hasgenerator(site.method)) && return [SyntaxNode[] for _ in code.code]
    return [collect(SyntaxNode, found) for found in first(TypedSyntax.map_ssas_to_source(code, instance, site.node, 0))]
end

"""
Node of each statement of `code` in `file`: lone node `mapped` gives statement, kept when node spells statement's call
(`spells`) and calls of one callee map in evaluation order; `nothing` elsewhere.
"""
function statement_nodes(code::Core.CodeInfo, mapped::Vector{Vector{SyntaxNode}}, file::SyntaxFile)::Vector{Union{Nothing, SyntaxNode}}
    nodes = Union{Nothing, SyntaxNode}[nothing for _ in code.code]
    ends = Dict{Symbol, Int}()
    for (index, (statement, found)) in enumerate(zip(code.code, mapped))
        length(found) == 1 || continue
        node, call = only(found), statement_call(statement)
        if !isnothing(call)
            name = callee_name(code, call)
            !isnothing(name) && spells(file, node, name, length(call.args) - 1) || continue
            # Inner call runs first and ends first, so later call of one callee ends later in source.
            stop = last(Facts.trimmed_bytes(file.text, node))
            name in LOWERED || (get(ends, name, 0) < stop || continue; ends[name] = stop)
        end
        nodes[index] = node
    end
    return nodes
end

"""
Span of each statement of `code`: node span from `statement_nodes`; else start of debuginfo line, when that line lies in
definition; else method site span. Statement without own line takes line of statement before it.
Code from macro of same file carries line of macro body, outside definition, so it gets method site span.
"""
function spans(code::Core.CodeInfo, instance::Core.MethodInstance, site::MethodSite, starts::Vector{Int})::Vector{Span}
    path = site.file.path
    lines = isnothing(site.node) ? (1:length(starts)) : searchsortedlast(starts, site.span.first_byte):searchsortedlast(starts, site.span.last_byte)
    found, line = Span[], 0
    for (index, node) in enumerate(statement_nodes(code, mappings(code, instance, site), site.file))
        scopes = Base.IRShow.buildLineInfoNode(code.debuginfo, instance, index)
        if !isempty(scopes)
            # Outermost scope is method itself, even for code from macro of other file; corpus run found no exception.
            string(first(scopes).file) == path || error("debuginfo of $(site.method) starts outside its file: $(first(scopes).file)")
            line = first(scopes).line in lines ? Int(first(scopes).line) : 0
        end
        push!(found, !isnothing(node) ? Facts.span(site.file, node) : line > 0 ? Span(path, starts[line], starts[line], Precision.line) : site.span)
    end
    return found
end

"""Whether `type` is stand-in type or holds one as parameter: `ArrayStandIn{FloatStandIn, 1}`, `Circle{IntStandIn}`."""
holds_stand_in(type::Any)::Bool = type isa DataType && (parentmodule(type) === StandIns || any(holds_stand_in, type.parameters))

"""Methods calls of `code` reach with concrete argument types that hold stand-in, with call signature."""
function reached(code::Core.CodeInfo, instance::Core.MethodInstance)::Vector{Tuple{Method, Type}}
    parameters = CC.sptypes_from_meth_instance(instance)
    found = Tuple{Method, Type}[]
    for statement in code.code
        call = statement_call(statement)
        isnothing(call) && continue
        types = Any[CC.widenconst(CC.argextype(argument, code, parameters)) for argument in call.args]
        call_signature = Tuple{types...}
        isconcretetype(call_signature) && any(holds_stand_in, types) || continue
        matches = Base._methods_by_ftype(call_signature, 1, Base.get_world_counter())
        matches isa Vector && length(matches) == 1 || continue
        push!(found, (only(matches).method, call_signature))
    end
    return found
end

"""
Typed code of package methods in `files` on stand-in signatures, then of package methods their calls reach, and blind spots:
signatures over `LIMIT`, argument without stand-in, inference that gives no code, untyped method no call reaches.
"""
function inference_facts(package::PackageFacts, files::Vector{SyntaxFile})::Tuple{InferenceFacts, Vector{BlindSpot}}
    structs = struct_stand_ins(Type[site.type for site in package.structs])
    spots = BlindSpot[]
    pending, skipped = Tuple{MethodSite, Type}[], MethodSite[]
    for site in package.methods
        untyped(site) && (push!(skipped, site); continue)
        found = method_signatures(site.method, structs)
        found.over_limit && push!(spots, BlindSpot("signatures over limit", site.span))
        # Explicit `::Any` and unbounded type variable hide nothing compiler knows, so only narrower declared types count.
        any(position -> Facts.argument_type(site.method, position) != Any, found.bare) && push!(spots, BlindSpot("argument without stand-in", site.span))
        append!(pending, ((site, signature) for signature in found.signatures))
    end
    by_path = Dict(file.path => file for file in files)
    lines = Dict(file.path => Package.Lines(file) for file in files)
    sites = Dict(site.method => site for site in package.methods)
    typed, seen, counts = TypedCode[], Set{Tuple{Method, Type}}(), Dict{Method, Int}()
    while !isempty(pending)
        site, call_signature = popfirst!(pending)
        key = (site.method, call_signature)
        key in seen && continue
        push!(seen, key)
        # Calls can reach one method with ever new types (`f(x) = f((x,))`), so reached signatures stop at limit.
        counts[site.method] = get(counts, site.method, 0) + 1
        counts[site.method] > LIMIT && (push!(spots, BlindSpot("signatures over limit", site.span)); continue)
        inferred = infer(site.method, call_signature)
        isnothing(inferred) && (push!(spots, BlindSpot("inference gave no code", site.span)); continue)
        instance, code, result = inferred
        push!(typed, TypedCode(site, call_signature, code, result, spans(code, instance, site, lines[site.file.path].starts)))
        # Package methods are those analyzed files define; others (Base) stay outside.
        for (method, signature) in reached(code, instance)
            file = get(by_path, string(method.file), nothing)
            isnothing(file) && continue
            callee = get!(() -> Package.method_site(method, file, lines[file.path]), sites, method)
            push!(pending, (callee, signature))
        end
    end
    inferred = Set(code.site.method for code in typed)
    append!(spots, BlindSpot("untyped method no call reaches", site.span) for site in skipped if !(site.method in inferred))
    return InferenceFacts(typed), unique!(spots)
end

end
