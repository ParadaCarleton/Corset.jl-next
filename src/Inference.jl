"""
`inference` stage: infer package methods on stand-in signatures (`Signatures`); map typed statements to source spans.

Inference runs on unoptimized code, since TypedSyntax.jl maps unoptimized statements to nodes of `syntax` stage tree.
Method with untyped argument is inferred only where inferred package code calls it with stand-in types.
Method store keeps result per method and signature across runs; entry holds while file and code it read stay same.
`Widening` scans typed code for weak values that change input type.
"""
module Inference

using Serialization: serialize, deserialize
using SHA: sha256
using TypedSyntax: TypedSyntax
using ..Facts: Facts, PackageFacts, InferenceFacts, FailingCall, Disruption, MethodSite, SyntaxFile, SyntaxNode, Span, Precision, BlindSpot, Confidence, Weak, Exit
using ..Facts: children_of, kind_name, identifier_name, source, signature, callee_node, call_arguments, name_span
using ..Package: Package
using ..StandIns: StandIns
using ..Widening: Widening
using ..Signatures: LIMIT, method_signatures, struct_stand_ins

const CC = Core.Compiler

"""
Typed code of package method on one signature: method site, signature, unoptimized typed statements, inferred result
type, and span of each statement. Span is exact where syntax node spells statement (`statement_nodes`); line precision
elsewhere. Code stays inside stage; method store keeps `Inferred` record of it.
"""
struct TypedCode
    site::MethodSite
    signature::Type
    code::Core.CodeInfo
    result::Type
    spans::Vector{Span}
end

"""
Result of inferring one method on one signature, as method store keeps it: call signatures of package methods its calls
reach, call statements that never return by statement index (`failures!`), whether inference gave code, and weak
values that change input type (`disruptions`).
"""
struct Inferred
    reached::Vector{Type}
    failures::Vector{Pair{Int, Union{FailingCall, BlindSpot}}}
    coded::Bool
    disruptions::Vector{Disruption}
end

"""
Instance of `@generated` package method that inference read: `method_id`, serialized signature, `entry_key` and digest
of generated code. Generator can call any package code, so store checks its output.
"""
struct Staged
    method::String
    signature::Vector{UInt8}
    key::String
    code::String
end

"""
Method store entry: content hash of file of method, since spans hold byte offsets; `code_digest` of each package method
inference read, by `method_id`; generated code it read; and serialized `Inferred` result. Result stays bytes until entry
proves valid: it can name closure type that edit removed.
"""
struct Entry
    file::Pair{String, String}
    methods::Vector{Pair{String, String}}
    staged::Vector{Staged}
    inferred::Vector{UInt8}
end

"""Method store: entries by `entry_key` of method and signature."""
const Store = Dict{String, Entry}

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
    return any(untyped_argument, parts.arguments[1:(length(Facts.tuple_parameters(site.method.sig)) - 1)])
end

"""
Whether method of `site` is one lowering makes to forward call: it declares fewer arguments than source, for omitted
default values or keyword group.
"""
function forwards(site::MethodSite)::Bool
    parts = isnothing(site.node) ? nothing : signature(site.node)
    isnothing(parts) && return false
    return length(Facts.tuple_parameters(site.method.sig)) - 1 < length(parts.arguments)
end

"""Method instance of `method` on `signature`, with static parameters bound; `nothing` when `signature` misses method."""
function instance(method::Method, signature::Type)::Union{Nothing, Core.MethodInstance}
    intersection, environment = ccall(:jl_type_intersection_with_env, Any, (Any, Any), signature, method.sig)::Core.SimpleVector
    return intersection === Union{} ? nothing : CC.specialize_method(method, intersection, environment)
end

"""
Unoptimized typed code of `method` on `signature`, its method instance, result type and compiler edges (callees result
depends on); `nothing` when inference gives none.
"""
function infer(method::Method, signature::Type)::Union{Nothing, Tuple{Core.MethodInstance, Core.CodeInfo, Type, Vector{Any}}}
    specialized = instance(method, signature)
    isnothing(specialized) && return nothing
    frame = CC.typeinf_frame(CC.NativeInterpreter(), specialized, false)
    return isnothing(frame) ? nothing : (specialized, frame.src, CC.widenconst(CC.ignorelimited(frame.result.result)), frame.edges)
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

"""
Whether `node` spells call to `name` with `arguments` positional arguments; callee lowering inserts passes. Product
`2x` spells call to `*`.
"""
function spells(file::SyntaxFile, node::SyntaxNode, name::Symbol, arguments::Int)::Bool
    name in LOWERED && return true
    kind_name(node) == "juxtapose" && return name === :* && length(children_of(node)) == arguments
    kind_name(node) == "call" || return false
    positional = count(part -> kind_name(part) != "parameters", call_arguments(node))
    return positional == arguments && Package.unqualified(source(file, callee_node(node))) == string(name)
end

"""Syntax nodes TypedSyntax.jl maps each statement of `code` to; none for generated function output or site without definition node."""
function mappings(code::Core.CodeInfo, instance::Core.MethodInstance, site::MethodSite)::Vector{Vector{SyntaxNode}}
    (isnothing(site.node) || Base.hasgenerator(site.method)) && return [SyntaxNode[] for _ in code.code]
    # Inference wraps unreached statements in `Core.Const`. TypedSyntax.jl maps only statements later code reads, so it
    # would skip call that never returns; unwrapped copy shows those reads.
    unwrapped = copy(code)
    unwrapped.code = Any[statement isa Core.Const ? statement.val : statement for statement in code.code]
    # Barrier: package that loads later invalidates TypedSyntax.jl line lookup (`promote_rule`), which would take caller too.
    mapped = Base.inferencebarrier(TypedSyntax.map_ssas_to_source)(unwrapped, instance, site.node, 0)[1]::Vector{Vector{TypedSyntax.MaybeTypedSyntaxNode}}
    return [collect(SyntaxNode, found) for found in mapped]
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
    for (index, statement) in enumerate(code.code)
        call = statement_call(statement)
        isnothing(nodes[index]) && !isnothing(call) && callee_name(code, call) === :broadcasted || continue
        nodes[index] = broadcast_node(code, nodes, index)
    end
    return nodes
end

"""
Dotcall node of `broadcasted` statement `index` of `code`: node of `materialize` statement that consumes it. Mapping
gives outermost broadcast of `xs .* 0.5 .+ 1.0` to its `materialize` statement only. `nothing` for other consumer.
"""
function broadcast_node(code::Core.CodeInfo, nodes::Vector{Union{Nothing, SyntaxNode}}, index::Int)::Union{Nothing, SyntaxNode}
    for user in (index + 1):length(code.code)
        call = statement_call(code.code[user])
        (isnothing(call) || !(Core.SSAValue(index) in call.args)) && continue
        return callee_name(code, call) === :materialize ? nodes[user] : nothing
    end
    return nothing
end

"""
Span of each statement of `code`: span of its node in `nodes` (`statement_nodes`); else start of debuginfo line, when
that line lies in definition; else method site span. Statement without own line takes line of statement before it.
Code from macro of same file carries line of macro body, outside definition, so it gets method site span.
"""
function spans(code::Core.CodeInfo, instance::Core.MethodInstance, site::MethodSite, starts::Vector{Int}, nodes::Vector{Union{Nothing, SyntaxNode}})::Vector{Span}
    path = site.file.path
    lines = isnothing(site.node) ? (1:length(starts)) : searchsortedlast(starts, site.span.first_byte):searchsortedlast(starts, site.span.last_byte)
    found, line = Span[], 0
    # Lowering gives method for omitted defaults first body line, though definition line holds defaults and forwarding call.
    wrapper = forwards(site)
    for (index, node) in enumerate(nodes)
        scopes = Base.IRShow.buildLineInfoNode(code.debuginfo, instance, index)
        if !isempty(scopes)
            # Outermost scope is method itself, even for code from macro of other file; corpus run found no exception.
            string(first(scopes).file) == path || error("debuginfo of $(site.method) starts outside its file: $(first(scopes).file)")
            scope_line = wrapper ? site.method.line : first(scopes).line
            line = scope_line in lines ? Int(scope_line) : 0
        end
        push!(found, !isnothing(node) ? Facts.span(site.file, node) : line > 0 ? Span(path, starts[line], starts[line], Precision.line) : site.span)
    end
    return found
end

"""
Node of weak value of `origin` inside its statement `node` of `code`: right side of assignment `s = 0`, which mapping
can give alone, argument or callee of call node that spells call (`spells`), or element of array literal. Broadcast
`f.(x)` lowers to `broadcasted(f, x)`, so positions shift by one. `nothing` when node cannot narrow: `[x 0.5; 1 2]`
lowers to `hvcat((2, 2), x, 0.5, 1, 2)`.
"""
function weak_node(code::Core.CodeInfo, node::Union{Nothing, SyntaxNode}, origin::Widening.Origin, file::SyntaxFile)::Union{Nothing, SyntaxNode}
    isnothing(node) && return nothing
    if origin.position == 0
        kind_name(node) == "=" && return children_of(node)[2]
        # Mapping that gives variable name holds no value.
        return source(file, node) == string(code.slotnames[(code.code[origin.index]::Expr).args[1].id]) ? nothing : node
    end
    call = something(statement_call(code.code[origin.index]))
    name, kind = callee_name(code, call), kind_name(node)
    # Product `2x` and array literal `[x, 0.5]` name no callee.
    if kind == "juxtapose" || (kind in ("vect", "hcat", "vcat") && name === Symbol(kind))
        parts, shift = children_of(node), 0
    elseif kind == "dotcall" && name === :broadcasted
        parts, shift = call_arguments(node), 1
    elseif kind == "call" && !isnothing(name) && Package.unqualified(source(file, callee_node(node))) == string(name)
        parts, shift = call_arguments(node), 0
    else
        return nothing
    end
    origin.position == 1 + shift && return kind in ("call", "dotcall") ? callee_node(node) : nothing
    positional = filter(part -> kind_name(part) != "parameters", parts)
    length(positional) == length(call.args) - 1 - shift || return nothing
    return positional[origin.position - 1 - shift]
end

"""
Text of type `type` with stand-ins as their models (`StandIns.model_type`); lazy broadcast prints as array it
materializes to.
"""
function type_text(type::Type)::String
    type <: Base.Broadcast.Broadcasted && (type = CC.return_type(Tuple{typeof(Base.Broadcast.materialize), type}))
    return string(StandIns.model_type(type))
end

"""Line precision span of line where `span` starts in `file`."""
function line_span(file::SyntaxFile, span::Span)::Span
    start = something(findprev(==(UInt8('\n')), codeunits(file.text), span.first_byte - 1), 0) + 1
    return Span(span.file, start, start, Precision.line)
end

"""
Disruption facts of `typed` code from weak value `changes` (`Widening.changes!`); `nodes` are its statement nodes.
Finding is `possible` when method tests type (`branch`) or node cannot narrow to weak value.
"""
function disruptions(typed::TypedCode, nodes::Vector{Union{Nothing, SyntaxNode}}, changes::Vector{Widening.Change}, branch::Bool)::Vector{Disruption}
    found = Disruption[]
    for change in changes
        origin, file = change.origin, typed.site.file
        node = weak_node(typed.code, nodes[origin.index], origin, file)
        statement = typed.code.code[origin.index]
        variable = origin.kind == Weak.variable ? string(typed.code.slotnames[(statement::Expr).args[1].id]) : ""
        confidence = branch || isnothing(node) ? Confidence.possible : Confidence.definite
        # Statement node that cannot narrow may be wrong one (`hvcat` maps to last row), so line stands for it.
        span = isnothing(node) ? line_span(file, typed.spans[origin.index]) : Facts.span(file, node)
        meeting, exit = isnothing(node) && origin.site == origin.index ? span : typed.spans[origin.site], typed.spans[change.at]
        # Implicit return maps to line only; on meeting line, meeting span shows it better.
        exit.precision == Precision.line && exit.first_byte <= meeting.first_byte && !occursin('\n', file.text[exit.first_byte:meeting.first_byte]) && (exit = meeting)
        push!(
            found, Disruption(
                span, meeting, exit,
                origin.kind, isnothing(node) ? repr(origin.value) : source(file, node), origin.value isa AbstractFloat ? Float64(origin.value) : nothing,
                string(origin.kind == Weak.name ? origin.value : typeof(origin.value)), variable, type_text(StandIns.model(StandIns.FloatStandIn)), type_text(change.found), type_text(change.expected), change.exit, confidence,
            )
        )
    end
    return found
end

"""Whether `type` is stand-in type or holds one as parameter: `ArrayStandIn{FloatStandIn, 1}`, `Circle{IntStandIn}`."""
holds_stand_in(type::Any)::Bool = type isa DataType && (parentmodule(type) === StandIns || any(holds_stand_in, type.parameters))

"""Signatures of calls in `code` with concrete argument types that hold stand-in and dispatch to one method."""
function reached(code::Core.CodeInfo, instance::Core.MethodInstance)::Vector{Type}
    parameters = CC.sptypes_from_meth_instance(instance)
    found = Type[]
    for statement in code.code
        call = statement_call(statement)
        isnothing(call) && continue
        types = Any[CC.widenconst(CC.argextype(argument, code, parameters)) for argument in call.args]
        call_signature = Tuple{types...}
        isconcretetype(call_signature) && any(holds_stand_in, types) || continue
        matches = Base._methods_by_ftype(call_signature, 1, Base.get_world_counter())
        matches isa Vector && length(matches) == 1 && push!(found, call_signature)
    end
    return found
end

"""Method call `signature` dispatches to; stage keeps only signatures that dispatch to one method."""
dispatched(signature::Type)::Method = only(Base._methods_by_ftype(signature, 1, Base.get_world_counter())::Vector).method

"""
Throw helper verdict on `callee`, with compiler edges of inferences it ran. Helper: `throw`, or function each of whose
methods throws for every argument type it declares (`error`, `rethrow`, `Base.Enums.enum_argument_error`). Fallback
method that throws for one missing interface does not make function helper.
"""
function throw_helper(callee::Any)::Tuple{Bool, Vector{Any}}
    callee === throw && return true, Any[]
    found, edges = methods(callee), Any[]
    isempty(found) && return false, edges
    for method in found
        inferred = infer(method, method.sig)
        isnothing(inferred) && return false, edges
        append!(edges, inferred[4])
        inferred[3] === Union{} || return false, edges
    end
    return true, edges
end

"""
Callable value of inferred `type`: its singleton, or type name of constructor with unknown parameters
(`Type{Point{T}} where T` gives `Point`); else `nothing`.
"""
function callable(type::Any)::Any
    singleton = CC.singleton_type(type)
    !isnothing(singleton) && return singleton
    bare = Base.unwrap_unionall(CC.widenconst(type))
    bare isa DataType && bare.name === Base.typename(Type) || return nothing
    constructed = Base.unwrap_unionall(only(bare.parameters))
    return constructed isa DataType ? constructed.name.wrapper : nothing
end

"""
Function or type `call` calls, when inference knows it: inner callee of splatted call (`Core._apply_iterate`) and keyword
call (`Core.kwcall`); else `nothing`.
"""
function called(code::Core.CodeInfo, call::Expr, parameters::Vector{CC.VarState})::Any
    callee = callable(CC.argextype(call.args[1], code, parameters))
    callee in (Core._apply_iterate, Core.kwcall) && length(call.args) >= 3 && return callable(CC.argextype(call.args[3], code, parameters))
    return callee
end

"""Whether `call` dispatches to one method that analyzed `files` define; its own frame reports failure inside it."""
function package_call(code::Core.CodeInfo, call::Expr, parameters::Vector{CC.VarState}, files::Dict{String, SyntaxFile})::Bool
    types = Any[CC.widenconst(CC.argextype(argument, code, parameters)) for argument in call.args]
    matches = Base._methods_by_ftype(Tuple{types...}, 1, Base.get_world_counter())
    return matches isa Vector && length(matches) == 1 && haskey(files, string(only(matches).method.file))
end

"""
Inferred type of statement `index` of `method` on `signature`, `Union{}` when it never returns, `nothing` without code.
Adds compiler edges of inference to `edges`.
"""
function statement_type!(edges::Vector{Any}, method::Method, signature::Type, index::Int)::Union{Nothing, Type}
    inferred = infer(method, signature)
    isnothing(inferred) && return nothing
    append!(edges, inferred[4])
    return CC.widenconst(inferred[2].ssavaluetypes[index])
end

"""Name of called function or type; text of other callable value."""
callee_text(callee::Any)::String = callee isa Union{Function, DataType, UnionAll} ? string(nameof(callee)) : repr(callee)

"""
Call statements of `typed` that never return, by statement index: fact, or blind spot where call returns once stand-ins
become their models. Skips unknown callees, calls of package methods in `files` and throw helpers. Adds compiler edges of
inferences it runs to `edges`; `helpers` caches throw-helper verdicts with their edges.
"""
function failures!(edges::Vector{Any}, helpers::IdDict{Any, Tuple{Bool, Vector{Any}}}, typed::TypedCode, files::Dict{String, SyntaxFile})::Vector{Pair{Int, Union{FailingCall, BlindSpot}}}
    found = Pair{Int, Union{FailingCall, BlindSpot}}[]
    method, code = typed.site.method, typed.code
    for (index, statement) in enumerate(code.code)
        # Unreached statement is wrapped in `Core.Const`, so it is no call.
        call = statement_call(statement)
        (isnothing(call) || code.ssavaluetypes[index] !== Union{}) && continue
        parameters = CC.sptypes_from_meth_instance(something(instance(method, typed.signature)))
        callee = called(code, call, parameters)
        (isnothing(callee) || package_call(code, call, parameters, files)) && continue
        helper, helper_edges = get!(() -> throw_helper(callee), helpers, callee)
        append!(edges, helper_edges)
        helper && continue
        # Model signature without code cannot confirm failure either, so it also counts as blind spot.
        modeled = statement_type!(edges, method, StandIns.model_type(typed.signature), index)
        modeled !== Union{} && (push!(found, index => BlindSpot("call fails on stand-in only", typed.spans[index])); continue)
        confidence = statement_type!(edges, method, method.sig, index) === Union{} ? Confidence.definite : Confidence.possible
        push!(found, index => FailingCall(typed.spans[index], name_span(typed.site), callee_text(callee), confidence))
    end
    return found
end

"""Method instance compiler edge `edge` stands for; `nothing` for other edge (binding, method-table lookup)."""
function edge_instance(edge::Any)::Union{Nothing, Core.MethodInstance}
    edge isa Core.CodeInstance && (edge = edge.def)
    edge isa Core.ABIOverride && (edge = edge.def)
    return edge isa Core.MethodInstance ? edge : nothing
end

"""Compiler edges of inference behind `edge`: those of code instance, or of first cached code instance of method instance."""
function edges_of(edge::Any)::Core.SimpleVector
    edge isa Core.CodeInstance && return edge.edges
    instance = edge_instance(edge)
    return isnothing(instance) || !isdefined(instance, :cache) ? Core.svec() : instance.cache.edges
end

"""Whether `type` names type or function of package `modules`, parameters included; `named` caches answers."""
function names_package!(named::IdDict{Any, Bool}, type::Any, modules::Set{Module})::Bool
    haskey(named, type) && return named[type]
    # Guard for type that names itself through parameter.
    named[type] = false
    answer = if type isa Union
        names_package!(named, type.a, modules) || names_package!(named, type.b, modules)
    elseif type isa UnionAll
        names_package!(named, type.body, modules)
    elseif type isa TypeVar
        names_package!(named, type.ub, modules)
    elseif type isa Core.TypeofVararg
        isdefined(type, :T) && names_package!(named, type.T, modules)
    elseif type isa DataType
        parentmodule(type) in modules || any(parameter -> names_package!(named, parameter, modules), type.parameters)
    else
        false
    end
    named[type] = answer
    return answer
end

"""
Package methods in analyzed `files` that inference results behind compiler `edges` read, with instances of `@generated`
ones apart. Walk passes through package methods and through dependency specializations that name package type
(`map(f, xs)` with package `f`). `nothing` when generated instance has signature store cannot read back (`holds_gensym`).
`named` caches `names_package!` answers.
"""
function dependency_methods!(named::IdDict{Any, Bool}, edges::Vector{Any}, files::Dict{String, SyntaxFile}, modules::Set{Module})::Union{Nothing, Tuple{Vector{Method}, Vector{Core.MethodInstance}}}
    found, staged, visited, stack = Method[], Core.MethodInstance[], Base.IdSet{Core.MethodInstance}(), copy(edges)
    while !isempty(stack)
        edge = pop!(stack)
        instance = edge_instance(edge)
        (isnothing(instance) || instance in visited) && continue
        push!(visited, instance)
        method = instance.def
        method isa Method || continue
        if haskey(files, string(method.file))
            Base.hasgenerator(method) ? (holds_gensym(instance.specTypes) && return nothing; push!(staged, instance)) : push!(found, method)
        else
            names_package!(named, instance.specTypes, modules) || continue
        end
        append!(stack, edges_of(edge))
    end
    return found, staged
end

"""
Whether `type` names type lowering names, parameters included: closure (`#g##0#g##1`) or keyword body (`#f#1`). Edit can
remove name, and then serialized type cannot load. Function `f` has type `#f`, but its `singletonname` is `f`.
"""
function holds_gensym(type::Any)::Bool
    type isa Union && return holds_gensym(type.a) || holds_gensym(type.b)
    type isa UnionAll && return holds_gensym(type.body)
    type isa DataType || return false
    return occursin('#', string(type.name.singletonname)) || any(holds_gensym, type.parameters)
end

"""Store key of `method` on `signature`: digest of both."""
entry_key(method::Method, signature::Type)::String = digest(Any[method.sig, signature])

"""Store name of `method`: digest of its signature, which no other method shares."""
method_id(method::Method)::String = digest(method.sig)

"""
Digest of lowered code of `method` as package load left it, macro output and `@eval` code included. Closure renamed by
edit has other code, so digest also checks what closure name means.
"""
code_digest(method::Method)::String = digest(Base.uncompressed_ast(method))

"""Digest of code generator of `@generated` method gives for `instance`; `nothing` digests too when generator throws."""
staged_digest(instance::Core.MethodInstance)::String = digest(CC.get_staged(instance, Base.get_world_counter()))

"""Methods defined in analyzed `files` by `method_id`, keyword bodies and closures included; `ids` keeps each one's id."""
function method_index(files::Dict{String, SyntaxFile})::Tuple{Dict{String, Method}, IdDict{Method, String}}
    ids = IdDict{Method, String}()
    Base.visit(method -> haskey(files, string(method.file)) && (ids[method] = method_id(method)), Core.methodtable)
    return Dict(id => method for (method, id) in ids), ids
end

"""
Entry `store` holds under `key` when file of method keeps its hash in `hashes`, each method entry read keeps its code,
and each generator it read gives same code. `index` finds methods by id; `codes` caches digests by id or staged key.
"""
function valid_entry(store::Store, key::String, hashes::Dict{String, String}, index::Dict{String, Method}, codes::Dict{String, String})::Union{Nothing, Entry}
    entry = get(store, key, nothing)
    (isnothing(entry) || get(hashes, first(entry.file), "") != last(entry.file)) && return nothing
    for (id, code) in entry.methods
        method = get(index, id, nothing)
        (isnothing(method) || get!(() -> code_digest(method), codes, id) != code) && return nothing
    end
    for staged in entry.staged
        method = get(index, staged.method, nothing)
        isnothing(method) && return nothing
        specialized = instance(method, deserialize(IOBuffer(staged.signature))::Type)
        (isnothing(specialized) || get!(() -> staged_digest(specialized), codes, staged.key) != staged.code) && return nothing
    end
    return entry
end

"""
Store entry of `inferred` result of `site` on `signature`, whose inferences gave compiler `edges`; `nothing` when walk
gives none (`dependency_methods!`). `ids` and `codes` cache method ids and digests.
"""
function entry!(named::IdDict{Any, Bool}, ids::IdDict{Method, String}, codes::Dict{String, String}, site::MethodSite, signature::Type, inferred::Inferred, edges::Vector{Any}, files::Dict{String, SyntaxFile}, hashes::Dict{String, String}, modules::Set{Module})::Union{Nothing, Entry}
    read = dependency_methods!(named, edges, files, modules)
    isnothing(read) && return nothing
    found, generated = read
    if Base.hasgenerator(site.method)
        holds_gensym(signature) && return nothing
        push!(generated, something(instance(site.method, signature)))
    else
        push!(found, site.method)
    end
    methods = Dict(get!(() -> method_id(method), ids, method) => method for method in found)
    digests = [id => get!(() -> code_digest(method), codes, id) for (id, method) in methods]
    records = Staged[]
    for specialized in generated
        method, key = specialized.def::Method, entry_key(specialized.def::Method, specialized.specTypes)
        push!(records, Staged(get!(() -> method_id(method), ids, method), serialized(specialized.specTypes), key, get!(() -> staged_digest(specialized), codes, key)))
    end
    return Entry(site.file.path => hashes[site.file.path], digests, records, serialized(inferred))
end

"""Serialized bytes of `data`, as store entry holds it."""
serialized(@nospecialize(data::Any))::Vector{UInt8} = (bytes = IOBuffer(); serialize(bytes, data); take!(bytes))

"""
Digest of serialized `data`: printed types depend on `Main` imports. Vector of `Any` compiles serializer once; tuple of
types would compile it once per tuple type.
"""
digest(@nospecialize(data::Any))::String = bytes2hex(sha256(sprint(serialize, Any[data])))

"""
Whether `value` is number, character, string, symbol, or immutable struct of those, tuples included: data that inference
or `@eval` loops of other files read.
"""
function plain(value::Any)::Bool
    value isa Union{Number, AbstractChar, String, Symbol} && return true
    (isstructtype(typeof(value)) && !ismutable(value)) || return false
    # Loop, since `all` over tuple compiles once per tuple type. Serializer writes undefined field too.
    for index in 1:nfields(value)
        (!isdefined(value, index) || plain(getfield(value, index))) || return false
    end
    return true
end

"""
Digest of layout of type `value`: type, supertype, mutability, and name and type of each field. Struct that edit
redefines serializes as before, so its fields count apart.
"""
function type_layout(value::Type)::String
    bare = Base.unwrap_unionall(value)
    bare isa DataType || return digest(value)
    layout = Any[value, supertype(bare), ismutabletype(bare)]
    # Field tuples would compile `append!` once per tuple type, so loop pushes each field.
    isstructtype(bare) && for index in 1:fieldcount(bare)
        push!(layout, fieldname(bare, index), fieldtype(bare, index))
    end
    return digest(layout)
end

"""
Shape text of constant `value`: layout for type (`type_layout`), name for function or module, code for enum value,
serialized value for `plain` value, else type. Inference reads constants (`const op = +`). Serializer throws for `@enum` value.
"""
function constant_text(value::Any)::String
    # Closure value would serialize its methods with their lines; name is stable.
    value isa Union{Function, Module} && return "$(parentmodule(value)).$(nameof(value))"
    value isa Type && return type_layout(value)
    value isa Enum && return digest(Any[typeof(value), Integer(value)])
    return plain(value) ? digest(value) : digest(typeof(value))
end

"""
Package shape that method store key hashes: signature and file of each package method; type of each global and shape
text of each constant (`constant_text`) in package modules, gensym names left out; text of each file that holds method
whose signature names no package type (piracy: any call can reach it, and walk sees no edge).
"""
function shape(package::PackageFacts)::Vector{String}
    modules, named, parts = Set(package.modules), IdDict{Any, Bool}(), String[]
    for site in package.methods
        push!(parts, "method $(site.file.path) $(digest(site.method.sig))")
        names_package!(named, site.method.sig, modules) || push!(parts, "piracy $(site.file.path) $(bytes2hex(sha256(site.file.text)))")
    end
    for mod in package.modules, name in names(mod; all = true)
        # Lowering names function types, closures and keyword bodies; entries check their code (`code_digest`).
        (isdefined(mod, name) && !occursin('#', string(name))) || continue
        if isconst(mod, name)
            push!(parts, "constant $mod.$name $(constant_text(getglobal(mod, name)))")
        else
            push!(parts, "global $mod.$name $(digest(Core.get_binding_type(mod, name)))")
        end
    end
    return unique!(parts)
end

"""
Run of inference stage: facts, blind spots, typed code of signatures it inferred, and store of entries it used.
Signatures: stand-in signatures of package methods in `files`, then those their calls reach. Blind spots: signatures over
`LIMIT`, argument without stand-in, inference that gives no code, untyped method no call reaches, call that fails on
stand-in only. `store` serves entries whose files are unchanged; `nothing` turns store off and gives no store.
"""
function infer_package(package::PackageFacts, files::Vector{SyntaxFile}, store::Union{Nothing, Store})::Tuple{InferenceFacts, Vector{BlindSpot}, Vector{TypedCode}, Union{Nothing, Store}}
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
    hashes = Dict(file.path => bytes2hex(sha256(file.text)) for file in files)
    used, modules, named, helpers = isnothing(store) ? nothing : Store(), Set(package.modules), IdDict{Any, Bool}(), IdDict{Any, Tuple{Bool, Vector{Any}}}()
    index, ids = isnothing(store) ? (Dict{String, Method}(), IdDict{Method, String}()) : method_index(by_path)
    codes = Dict{String, String}()
    typed, seen, counts, coded = TypedCode[], Set{Tuple{Method, Type}}(), Dict{Method, Int}(), Set{Method}()
    failing, gaps, settled, disrupting = FailingCall[], BlindSpot[], Set{Tuple{Method, Int}}(), Disruption[]
    while !isempty(pending)
        site, call_signature = popfirst!(pending)
        (site.method, call_signature) in seen && continue
        push!(seen, (site.method, call_signature))
        # Calls can reach one method with ever new types (`f(x) = f((x,))`), so reached signatures stop at limit.
        counts[site.method] = get(counts, site.method, 0) + 1
        counts[site.method] > LIMIT && (push!(spots, BlindSpot("signatures over limit", site.span)); continue)
        key = isnothing(store) ? "" : entry_key(site.method, call_signature)
        entry = isnothing(store) ? nothing : valid_entry(store, key, hashes, index, codes)
        if isnothing(entry)
            edges = Any[]
            result = infer(site.method, call_signature)
            inferred = if isnothing(result)
                Inferred(Type[], Pair{Int, Union{FailingCall, BlindSpot}}[], false, Disruption[])
            else
                instance, code, returned, frame_edges = result
                append!(edges, frame_edges)
                nodes = statement_nodes(code, mappings(code, instance, site), site.file)
                push!(typed, TypedCode(site, call_signature, code, returned, spans(code, instance, site, lines[site.file.path].starts, nodes)))
                changes, branch = Widening.changes!(edges, instance, code)
                Inferred(reached(code, instance), failures!(edges, helpers, last(typed), by_path), true, disruptions(last(typed), nodes, changes, branch))
            end
            entry = isnothing(used) ? nothing : entry!(named, ids, codes, site, call_signature, inferred, edges, by_path, hashes, modules)
        else
            inferred = deserialize(IOBuffer(entry.inferred))::Inferred
        end
        isnothing(used) || isnothing(entry) || (used[key] = entry)
        inferred.coded || (push!(spots, BlindSpot("inference gave no code", site.span)); continue)
        push!(coded, site.method)
        # Package methods are those analyzed files define; others (Base) stay outside.
        for signature in inferred.reached
            method = dispatched(signature)
            file = get(by_path, string(method.file), nothing)
            isnothing(file) && continue
            push!(pending, (get!(() -> Package.method_site(method, file, lines[file.path]), sites, method), signature))
        end
        for (index, failure) in inferred.failures
            (site.method, index) in settled && continue
            failure isa BlindSpot ? push!(gaps, failure) : (push!(settled, (site.method, index)); push!(failing, failure))
        end
        append!(disrupting, inferred.disruptions)
    end
    append!(spots, BlindSpot("untyped method no call reaches", site.span) for site in skipped if !(site.method in coded))
    # One finding per weak value: escape before intermediate, definite before possible.
    sort!(disrupting; by = disruption -> (disruption.exit == Exit.intermediate, disruption.confidence == Confidence.possible))
    return InferenceFacts(failing, unique!(disruption -> disruption.span, disrupting)), unique!(append!(spots, gaps)), typed, used
end

"""Inference facts of `package` in analyzed `files`, their blind spots, and store of entries run used (`infer_package`)."""
function inference_facts(package::PackageFacts, files::Vector{SyntaxFile}, store::Union{Nothing, Store})::Tuple{InferenceFacts, Vector{BlindSpot}, Union{Nothing, Store}}
    facts, spots, _, used = infer_package(package, files, store)
    return facts, spots, used
end

end
