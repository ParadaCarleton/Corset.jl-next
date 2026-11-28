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
using EnumX: @enumx
using TypedSyntax: TypedSyntax
using ..Facts: Facts, PackageFacts, InferenceFacts, FailingCall, EndlessCycle, Label, Disruption, HardArray, NarrowingLoss, StatefulIterate, MethodSite, SyntaxFile, SyntaxNode, Span, Precision, BlindSpot, Confidence, Weak, Exit
using ..Facts: children_of, kind_name, identifier_name, source, signature, callee_node, call_arguments, name_span, parent_of, ancestors, base_macro, resolve_type
using ..Package: Package
using ..StandIns: StandIns
using ..Widening: Widening, statement_call, statement_type, code_argextype
using ..Narrowing: Narrowing
using ..HardArrays: HardArrays
using ..Guesses: annotation_guesses
using ..Signatures: LIMIT, Provenance, method_signatures, struct_stand_ins, argument_provenance

const CC = Core.Compiler

"""
Typed code of package method on one signature: method site, signature, unoptimized typed statements, inferred result
type, span of each statement, discarded call statements without exact span (`discarded_nodes`), inference frame
(`effects` stage builds IR from it), provenance of each argument, callee first (`argument_provenance`), and stand-in
cuts (`cuts!`). Span is exact where syntax node spells statement (`statement_nodes`); line precision elsewhere. Code stays inside stage and `effects`; method store keeps `Inferred`.
"""
struct TypedCode
    site::MethodSite
    signature::Type
    code::Core.CodeInfo
    result::Type
    spans::Vector{Span}
    unmapped::BitSet
    frame::CC.InferenceState
    provenance::Vector{Provenance.T}
    cuts::Vector{Int}
end

"""
Unit that method store served (`Entry`): method site, signature, serialized `effects` stage record (empty when entry
keeps none), and count of typed units inferred before it, so `effects` stage keeps unit order.
"""
struct StoredUnit
    site::MethodSite
    signature::Type
    effects::Vector{UInt8}
    position::Int
end

"""
Units of `inference` stage run, for `effects` stage: typed code of each unit inferred this run, methods whose results
miss some argument types (`incomplete`): signatures over limit, crash, no code, or type test; and units method store
served (`stored`), which need no typed code.
"""
struct Units
    typed::Vector{TypedCode}
    incomplete::Set{Method}
    stored::Vector{StoredUnit}
end

"""
Result of inferring one method on one signature, as method store keeps it: call signatures of package methods its calls
reach, call statements that never return by statement index (`call_failures`), confidence that unit never returns nor
throws (`endless_verdict`) with its package calls that never return (call span => signature), whether inference gave code and whether
code tests type, weak values that change input type (`disruptions`), type tests whose narrowing guard drops
(`narrowings`), and `iterate` calls on `Iterators.Stateful` (`stateful_iterates`).
"""
struct Inferred
    returned::Type
    calls::Vector{Tuple{Type, Type}}
    reached::Vector{Type}
    failures::Vector{Pair{Int, Union{FailingCall, BlindSpot}}}
    endless::Union{Nothing, Confidence.T}
    endless_calls::Vector{Pair{Span, Type}}
    coded::Bool
    tests_type::Bool
    disruptions::Vector{Disruption}
    hard_arrays::Vector{HardArray}
    narrowings::Vector{NarrowingLoss}
    stateful_iterates::Vector{StatefulIterate}
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
inference read, by `method_id`; generated code it read; meaning of each package name it read (`meanings`); serialized
`Inferred` result; and serialized `effects` stage record of unit (`effects.md`, Solve and cache), empty until
`effects` run gives one. Result stays bytes until entry proves valid: it can name closure type that edit removed.
"""
struct Entry
    file::Pair{String, String}
    methods::Vector{Pair{String, String}}
    staged::Vector{Staged}
    names::Vector{Pair{String, String}}
    inferred::Vector{UInt8}
    effects::Vector{UInt8}
end

"""Method store: entries by `entry_key` of method and signature."""
const Store = Dict{String, Entry}

include("Inference/journal.jl")

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

"""Argument nodes of signature `parts`: positional ones, then each keyword of keyword group."""
argument_nodes(parts::@NamedTuple{call::SyntaxNode, arguments::Vector{SyntaxNode}, typed::Bool})::Vector{SyntaxNode} = [
    argument for node in parts.arguments for argument in (kind_name(node) == "parameters" ? children_of(node) : [node])
]

"""Whether argument `name` of method of `site` has annotation `::Any` in source; keyword of keyword body included."""
function explicit_any(site::MethodSite, name::Symbol)::Bool
    parts = isnothing(site.node) ? nothing : signature(site.node)
    isnothing(parts) && return false
    return any(node -> annotated_any(site, node, string(name)), argument_nodes(parts))
end

"""Whether positional argument `node` of signature of `site` declares argument `name` as `::Any`."""
function annotated_any(site::MethodSite, node::SyntaxNode, name::String)::Bool
    kind = kind_name(node)
    kind in ("=", "kw", "...") && return annotated_any(site, children_of(node)[1], name)
    kind == "::" && length(children_of(node)) == 2 || return false
    target, annotation = children_of(node)
    return kind_name(target) == "Identifier" && identifier_name(target) == name && resolve_type(site.method.module, site.file, annotation) === Any
end

"""
Whether method of `site` has argument without type in source. Explicit `::Any` opts out on purpose, so it counts as
typed. Site without definition node counts as typed. Keyword body (`body`) takes all positional arguments and keywords.
"""
function untyped(site::MethodSite, body::Bool)::Bool
    parts = isnothing(site.node) ? nothing : signature(site.node)
    isnothing(parts) && return false
    body && return any(untyped_argument, argument_nodes(parts))
    # Keyword group comes last, and method for omitted default values declares fewer arguments, so slice leaves out both.
    return any(untyped_argument, @view(parts.arguments[1:(length(Facts.tuple_parameters(site.method.sig)) - 1)]))
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
Output of `infer`: method instance, unoptimized typed code, result type, compiler edges (callees result depends on),
control flow with variable types per block, and inference frame.
"""
const Output = Tuple{Core.MethodInstance, Core.CodeInfo, Type, Vector{Any}, Narrowing.Flow, CC.InferenceState}

"""Output of inference of `method` on `signature`; `nothing` when inference gives none."""
function infer(method::Method, signature::Type)::Union{Nothing, Output}
    specialized = instance(method, signature)
    isnothing(specialized) && return nothing
    frame = CC.typeinf_frame(CC.NativeInterpreter(), specialized, false)
    isnothing(frame) && return nothing
    return specialized, frame.src, CC.widenconst(CC.ignorelimited(frame.result.result)), frame.edges, Narrowing.Flow(frame.cfg, frame.bb_vartables), frame
end

"""
Name of function `call` calls: global, or global earlier statement reads, or parametric type `Vector{T}` that earlier
statement applies, or qualified name `Base.iterate`; `nothing` for computed callee.
"""
function callee_name(code::Core.CodeInfo, call::Expr)::Union{Nothing, Symbol}
    callee = call.args[1]
    callee isa Core.SSAValue && (callee = code.code[callee.id])
    if callee isa Expr && callee.head === :call && length(callee.args) >= 2 && callee.args[1] == GlobalRef(Core, :apply_type)
        callee = callee.args[2]
        callee isa Core.SSAValue && (callee = code.code[callee.id])
    end
    return callee isa GlobalRef ? callee.name : qualified_name(code, callee)
end

"""
Name that `statement` reads from module: `Base.iterate` lowers to `getproperty(Base, :iterate)`; inner module
`Base.Iterators.peel` reads from earlier statement that inference types as module. `nothing` for field read.
"""
function qualified_name(code::Core.CodeInfo, @nospecialize(statement::Any))::Union{Nothing, Symbol}
    statement isa Expr && statement.head === :call && length(statement.args) == 3 && statement.args[1] == GlobalRef(Base, :getproperty) || return nothing
    quoted, owner = statement.args[3], statement.args[2]
    quoted isa QuoteNode || return nothing
    name = quoted.value
    name isa Symbol || return nothing
    owner isa Core.SSAValue && return (code.ssavaluetypes::Vector{Any})[owner.id] isa Core.Const && code.ssavaluetypes[owner.id].val isa Module ? name : nothing
    return owner isa GlobalRef && isdefinedglobal(owner.mod, owner.name) && getglobal(owner.mod, owner.name) isa Module ? name : nothing
end

"""
Whether `node` spells call to `name` with `arguments` positional arguments; callee lowering inserts passes. Product
`2x` spells call to `*`.
"""
spells(file::SyntaxFile, node::SyntaxNode, name::Symbol, arguments::Integer)::Bool = name in LOWERED || spells_call(file, node, name, arguments)

"""Whether `node` spells call to `name` with `arguments` positional arguments in source, lowered callee too."""
function spells_call(file::SyntaxFile, node::SyntaxNode, name::Symbol, arguments::Integer)::Bool
    kind_name(node) == "juxtapose" && return name === :* && length(children_of(node)) == arguments
    kind_name(node) == "call" || return false
    positional = count(part -> kind_name(part) != "parameters", call_arguments(node))
    callee = callee_node(node)
    # Parametric type callee `Vector{T}(undef, n)` spells its type name.
    kind_name(callee) == "curly" && (callee = children_of(callee)[1])
    return positional == arguments && Package.unqualified(source(file, callee)) == string(name)
end

"""Syntax nodes TypedSyntax.jl maps each statement of `code` to; none for generated function output or site without definition node."""
function mappings(code::Core.CodeInfo, instance::Core.MethodInstance, site::MethodSite)::Vector{Vector{SyntaxNode}}
    (isnothing(site.node) || Base.hasgenerator(site.method)) && return [SyntaxNode[] for _ in code.code]
    # Inference wraps unreached statements in `Core.Const`. TypedSyntax.jl maps only statements later code reads, so it
    # would skip call that never returns; unwrapped copy shows those reads.
    unwrapped = copy(code)
    unwrapped.code = Any[Widening.unwrapped(statement) for statement in code.code]
    # Barrier: package that loads later invalidates TypedSyntax.jl line lookup (`promote_rule`), which would take caller too.
    mapped = Base.inferencebarrier(TypedSyntax.map_ssas_to_source)(unwrapped, instance, site.node, 0)[1]::Vector{Vector{TypedSyntax.MaybeTypedSyntaxNode}}
    return [collect(SyntaxNode, found) for found in mapped]
end

"""
Node of each statement of `code` in `file`: lone node `mapped` gives statement, kept when node spells statement's call
(`spells`) and calls of one callee map in evaluation order; `nothing` elsewhere.
"""
function statement_nodes(code::Core.CodeInfo, mapped::AbstractVector{<:AbstractVector{SyntaxNode}}, file::SyntaxFile)::Vector{Union{Nothing, SyntaxNode}}
    nodes = Union{Nothing, SyntaxNode}[nothing for _ in code.code]
    ends = Dict{Symbol, Int}()
    for (index, (statement, found)) in enumerate(zip(code.code, mapped))
        length(found) == 1 || continue
        node, call = only(found), statement_call(statement)
        if !isnothing(call)
            name = callee_name(code, call)
            isnothing(name) && continue
            spells(file, node, name, length(call.args) - 1) || continue
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
function broadcast_node(code::Core.CodeInfo, nodes::AbstractVector{Union{Nothing, SyntaxNode}}, index::Integer)::Union{Nothing, SyntaxNode}
    Base.require_one_based_indexing(nodes)
    for user in (index + 1):length(code.code)
        call = statement_call(code.code[user])
        (isnothing(call) || !(Core.SSAValue(index) in call.args)) && continue
        return callee_name(code, call) === :materialize ? nodes[user] : nothing
    end
    return nothing
end

include("Inference/discarded.jl")

"""
Span of each statement of `code`: span of its node in `nodes` (`statement_nodes`), or of discarded call statement
(`discarded_nodes`); else start of debuginfo line, when that line lies in definition; else method site span. Statement
without own line takes line of statement before it. Code from macro of same file carries line of macro body, outside
definition, so it gets method site span. Second result holds discarded call statements mapping cannot place.
"""
function spans(code::Core.CodeInfo, instance::Core.MethodInstance, site::MethodSite, starts::AbstractVector{<:Integer}, nodes::AbstractVector{Union{Nothing, SyntaxNode}})::Tuple{Vector{Span}, BitSet}
    # Debuginfo line number indexes `starts`.
    Base.require_one_based_indexing(nodes, starts)
    path = site.file.path
    inside = isnothing(site.node) ? eachindex(starts) : searchsortedlast(starts, site.span.first_byte):searchsortedlast(starts, site.span.last_byte)
    lines, line = zeros(Int, length(nodes)), 0
    # Lowering gives method for omitted defaults first body line, though definition line holds defaults and forwarding call.
    wrapper = forwards(site)
    for index in eachindex(nodes)
        scopes = Base.IRShow.buildLineInfoNode(code.debuginfo, instance, index)
        if !isempty(scopes)
            # Outermost scope is method itself, even for code from macro of other file; corpus run found no exception.
            string(first(scopes).file) == path || error("debuginfo of $(site.method) starts outside its file: $(first(scopes).file)")
            scope_line = wrapper ? site.method.line : first(scopes).line
            line = scope_line in inside ? Int(scope_line) : 0
        end
        lines[index] = line
    end
    discarded, unmapped = discarded_nodes(site.file, code, nodes, lines, discarded_calls(site, starts))
    found = Span[]
    for (index, line) in enumerate(lines)
        node = something(nodes[index], get(discarded, index, nothing), Some(nothing))
        push!(found, !isnothing(node) ? Facts.span(site.file, node) : line > 0 ? Span(path, starts[line], starts[line], Precision.line) : site.span)
    end
    return found, unmapped
end

"""
Node of weak value of `origin` inside its statement `node` of `code`: right side of assignment `s = 0`, which mapping
can give alone, argument or callee of call node that spells call (`spells`), or element of array literal. Broadcast
`f.(x)` lowers to `broadcasted(f, x)`, so positions shift by one. `nothing` when node cannot narrow: `[x 0.5; 1 2]`
lowers to `hvcat((2, 2), x, 0.5, 1, 2)`.
"""
function weak_node(code::Core.CodeInfo, node::Union{Nothing, SyntaxNode}, origin::Widening.Origin, file::SyntaxFile)::Union{Nothing, SyntaxNode}
    isnothing(node) && return nothing
    # Origin from later widening round can sit in statement original inference left unreached.
    statement = Widening.unwrapped(code.code[origin.index])
    if origin.position == 0
        kind_name(node) == "=" && return children_of(node)[2]
        # Mapping that gives variable name holds no value.
        return source(file, node) == string(code.slotnames[(statement::Expr).args[1].id]) ? nothing : node
    end
    call = something(statement_call(statement))
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
Names of variables `code` assigns. Lowering copies reassigned argument into local of same name, so argument name
in this set may not hold argument.
"""
function assigned_names(code::Core.CodeInfo)::Set{Symbol}
    # Typed loop: `Set(generator)` of unknown element type calls `grow_to!`, which package `iterate` methods invalidate.
    found = Set{Symbol}()
    for statement in code.code
        statement isa Expr && statement.head === :(=) && statement.args[1] isa Core.SlotNumber && push!(found, code.slotnames[statement.args[1].id])
    end
    return found
end

"""
Prefix and suffix that convert value to input float type of `typed` code of `instance`: static parameter bound to float
stand-in (`T(`), else argument of float stand-in type (`oftype(x, `), else array argument of float stand-in elements
(`eltype(xs)(`). Code must never assign argument name: lowering copies reassigned argument into local of same name.
`float` wraps name unless declared type admits floats only, since `oftype(1, 0.5)` throws. `nothing` when method has
none.
"""
function converter(typed::TypedCode, instance::Core.MethodInstance)::Union{Nothing, Pair{String, String}}
    method, stand_in = typed.site.method, StandIns.FloatStandIn
    signature, index = method.sig, 0
    while signature isa UnionAll
        index += 1
        parameter, signature = signature.var, signature.body
        # Type variable of `AbstractVector{<:Real}` has generated name (`#s1`) source cannot spell.
        if instance.sparam_vals[index] === stand_in && Base.isidentifier(parameter.name)
            return (parameter.ub <: AbstractFloat ? "$(parameter.name)(" : "float($(parameter.name))(") => ")"
        end
    end
    assigned = assigned_names(typed.code)
    arguments, found = Facts.tuple_parameters(typed.signature), nothing
    for slot in 2:length(arguments)
        name, type, declared = typed.code.slotnames[slot], arguments[slot], Facts.argument_type(method, slot - 1)
        (name in assigned || !Base.isidentifier(name) || !(type isa Type)) && continue
        type === stand_in && return (declared <: AbstractFloat ? "oftype($name, " : "oftype(float($name), ") => ")"
        type <: AbstractArray && eltype(type) === stand_in && isnothing(found) &&
            (found = (declared <: AbstractArray{<:AbstractFloat} ? "eltype($name)(" : "float(eltype($name))(") => ")")
    end
    return found
end

"""Macros that keep literal values as written, so conversion call may replace one inside them."""
const PLAIN_MACROS = ("@inline", "@noinline", "@inbounds", "@propagate_inbounds", "@fastmath", "@simd", "@views", "@assume_effects")

"""
Text that replaces weak value `node` of `origin` with it converted by `conversion` (`converter`); `nothing` when fix
cannot apply: no node or converter, weak value other than float number, product `2.0x`, or macro that rewrites code
(`@.` would dot conversion).
"""
function converted_text(file::SyntaxFile, node::Union{Nothing, SyntaxNode}, origin::Widening.Origin, conversion::Union{Nothing, Pair{String, String}})::Union{Nothing, String}
    (isnothing(node) || isnothing(conversion) || !(origin.value isa AbstractFloat)) && return nothing
    kind_name(parent_of(node)) == "juxtapose" && return nothing
    all(ancestor -> kind_name(ancestor) != "macrocall" || base_macro(ancestor) in PLAIN_MACROS, ancestors(node)) || return nothing
    return first(something(conversion)) * source(file, node) * last(something(conversion))
end

"""Container name of `Array` type `array`: `Vector`, `Matrix`, else `Array`. Element type of stand-in would mislead."""
container_text(array::Type)::String = array <: Vector ? "Vector" : array <: Matrix ? "Matrix" : "Array"

"""Literal kinds `fill` value may have in fix: value repeats in fix text, so it must evaluate to same value each time."""
const FILL_LITERALS = ("Integer", "Float", "Float32", "Bool", "Char", "HexInt", "BinInt", "OctInt")

"""Source text of first type parameter of `node` (`T` of `Vector{T}`); `nothing` for other syntax."""
function type_parameter(file::SyntaxFile, node::SyntaxNode)::Union{Nothing, String}
    kind_name(node) == "curly" || return nothing
    parts = children_of(node)
    return length(parts) >= 2 ? source(file, parts[2]) : nothing
end

"""
Text that builds array of construction `node` with `similar(template, T, dims)`, so it keeps template's array type:
`zeros(n)` gives `fill!(similar(xs, Float64, n), 0.0)`, `Vector{T}(undef, n)` gives `similar(xs, T, n)`. `nothing`
when code assigns template name or call has other form: no dimensions, `fill` value other than literal or name, or type
without parameter syntax. Keyword call lowers to `kwcall`, which is no construction.
"""
function rebuilt(typed::TypedCode, instance::Core.MethodInstance, construction::HardArrays.Construction, node::Union{Nothing, SyntaxNode}, template::String)::Union{Nothing, String}
    (isnothing(node) || !Base.isidentifier(template) || Symbol(template) in assigned_names(typed.code)) && return nothing
    file, callee, parts = typed.site.file, construction.callee, call_arguments(node)
    texts = [source(file, part) for part in parts]
    if callee === zeros || callee === ones
        call = something(statement_call(typed.code.code[construction.index]))
        typed_first = CC.widenconst(code_argextype(call.args[2], typed.code, CC.sptypes_from_meth_instance(instance))) <: Type
        element = typed_first ? texts[1] : "Float64"
        value = typed_first ? "$(callee === zeros ? "zero" : "one")($element)" : callee === zeros ? "0.0" : "1.0"
        dimensions = typed_first ? texts[2:end] : texts
    elseif callee === fill
        kind = kind_name(parts[1])
        element = kind == "Identifier" ? "typeof($(texts[1]))" : kind in FILL_LITERALS ? string(eltype(construction.array)) : nothing
        value, dimensions = texts[1], texts[2:end]
    else
        # `similar(Vector{T}, n)` names type first; `Vector{T}(undef, n)` names it as callee.
        element = type_parameter(file, callee === similar ? parts[1] : callee_node(node))
        value, dimensions = nothing, texts[2:end]
    end
    (isnothing(element) || isempty(dimensions)) && return nothing
    built = "similar($template, $element, $(join(dimensions, ", ")))"
    return isnothing(value) ? built : "fill!($built, $value)"
end

"""
Hard-coded array facts of `typed` code of `instance` from `changes` (`HardArrays.changes!`); `nodes` are its statement
nodes. Escape is `possible` when method tests type (`branch`) or node cannot narrow; meeting is `possible` always, since
caller's array type decides whether mixing fails (GPU array with CPU array).
"""
function hard_arrays(typed::TypedCode, instance::Core.MethodInstance, nodes::AbstractVector{Union{Nothing, SyntaxNode}}, changes::AbstractVector{HardArrays.Change}, branch::Bool)::Vector{HardArray}
    Base.require_one_based_indexing(nodes)
    found, file = HardArray[], typed.site.file
    for change in changes
        construction = change.construction
        node = nodes[construction.index]
        (isnothing(node) || kind_name(node) == "call") || (node = nothing)
        span = isnothing(node) ? line_span(file, typed.spans[construction.index]) : Facts.span(file, node)
        exit = typed.spans[change.at]
        # Implicit return maps to line only; on construction line, construction span shows it better.
        exit.precision == Precision.line && exit.first_byte <= span.first_byte && !occursin('\n', file.text[exit.first_byte:span.first_byte]) && (exit = span)
        template = string(typed.code.slotnames[construction.template])
        definite = change.exit != Exit.intermediate && !branch && !isnothing(node)
        push!(
            found, HardArray(
                span, exit, change.exit, isnothing(node) ? "" : source(file, node), container_text(construction.array), template,
                rebuilt(typed, instance, construction, node, template), definite ? Confidence.definite : Confidence.possible,
            )
        )
    end
    return found
end

"""
`iterate` calls on `Iterators.Stateful` in `typed` code of `instance`; `nodes` are its statement nodes. Call needs node
that spells `iterate`: `for` loop lowers to `iterate` too, and its node is loop.
"""
function stateful_iterates(typed::TypedCode, instance::Core.MethodInstance, nodes::AbstractVector{Union{Nothing, SyntaxNode}})::Vector{StatefulIterate}
    found, file, parameters = StatefulIterate[], typed.site.file, CC.sptypes_from_meth_instance(instance)
    for (statement, node) in zip(typed.code.code, nodes)
        call = statement_call(statement)
        (isnothing(call) || isnothing(node) || length(call.args) ∉ (2, 3)) && continue
        code_argextype(call.args[1], typed.code, parameters) == Core.Const(iterate) || continue
        CC.widenconst(code_argextype(call.args[2], typed.code, parameters)) <: Iterators.Stateful || continue
        kind_name(node) == "call" && Package.unqualified(source(file, callee_node(node))) == "iterate" || continue
        push!(found, StatefulIterate(Facts.span(file, node), source(file, call_arguments(node)[1])))
    end
    return found
end

"""
Disruption facts of `typed` code of `instance` from weak value `changes` (`Widening.changes!`); `nodes` are its
statement nodes. Finding is `possible` when method tests type (`branch`) or node cannot narrow to weak value.
"""
function disruptions(typed::TypedCode, instance::Core.MethodInstance, nodes::AbstractVector{Union{Nothing, SyntaxNode}}, changes::AbstractVector{Widening.Change}, branch::Bool)::Vector{Disruption}
    Base.require_one_based_indexing(nodes)
    found, conversion = Disruption[], isempty(changes) ? nothing : converter(typed, instance)
    for change in changes
        origin, file = change.origin, typed.site.file
        node = weak_node(typed.code, nodes[origin.index], origin, file)
        statement = Widening.unwrapped(typed.code.code[origin.index])
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
                converted_text(file, node, origin, conversion),
            )
        )
    end
    return found
end

"""
Lost narrowing facts of `typed` code from `losses` (`Narrowing.losses`); `nodes` are its statement nodes. Loss counts
when test maps to term of `&&` or `||` chain (`Narrowing.guard`).
"""
function narrowings(typed::TypedCode, nodes::AbstractVector{Union{Nothing, SyntaxNode}}, losses::AbstractVector{Narrowing.Loss})::Vector{NarrowingLoss}
    Base.require_one_based_indexing(nodes)
    found, file = NarrowingLoss[], typed.site.file
    for loss in losses
        node = nodes[loss.test]
        guarded = isnothing(node) ? nothing : Narrowing.guard(file, node)
        isnothing(guarded) && continue
        push!(
            found, NarrowingLoss(
                Facts.span(file, guarded.term), Facts.span(file, guarded.statement), typed.spans[loss.read], string(typed.code.slotnames[loss.slot]),
                type_text(loss.narrowed), type_text(loss.found), kind_name(guarded.chain), guarded.split,
            )
        )
    end
    return found
end

"""
Whether `type` is stand-in type or holds one as parameter or variable bound: `ArrayStandIn{<:Any, 1}`,
`Circle{IntStandIn}`, view of open stand-in (`SubArray{T, 1, P} where {T, P <: ArrayStandIn{<:Any, 2}}`).
"""
function holds_stand_in(@nospecialize(type::Any))::Bool
    type isa TypeVar && return holds_stand_in(type.ub)
    type = Base.unwrap_unionall(type)
    return type isa DataType && (parentmodule(type) === StandIns || any(holds_stand_in, type.parameters))
end

"""
Whether every value of `type` has concrete type: concrete type, or struct family (`ArrayStandIn{<:Any, 1}`, its views).
Struct type is concrete whatever its parameters; tuple is concrete only when its members are.
"""
function settled(@nospecialize(type::Any))::Bool
    type isa UnionAll || return isconcretetype(type)
    body = Base.unwrap_unionall(type)
    return body isa DataType && isstructtype(body) && !(body <: Tuple)
end

"""
Calls in typed `code` of `instance` to function of package `modules` with concrete argument types that dispatch to one
method of analyzed files (`by_path`): statement index, signature, and type inference gives call there. Annotation
guesses and endless cycles read them.
"""
function package_calls(code::Core.CodeInfo, instance::Core.MethodInstance, modules::AbstractSet{Module}, by_path::AbstractDict{String, SyntaxFile})::Vector{Tuple{Int, Type, Type}}
    parameters = CC.sptypes_from_meth_instance(instance)
    found = Tuple{Int, Type, Type}[]
    for (index, statement) in enumerate(code.code)
        call = statement_call(statement)
        isnothing(call) && continue
        callee = CC.widenconst(code_argextype(call.args[1], code, parameters))
        (callee isa DataType && callee <: Function && parentmodule(callee) in modules) || continue
        types = Any[CC.widenconst(code_argextype(argument, code, parameters)) for argument in call.args]
        all(settled, types) || continue
        call_signature = Tuple{types...}
        matches = Base._methods_by_ftype(call_signature, 1, Base.get_world_counter())
        (matches isa Vector && length(matches) == 1 && haskey(by_path, string(only(matches).method.file))) || continue
        push!(found, (index, call_signature, statement_type(code, index)))
    end
    return found
end

"""Signatures of calls in `code` with concrete argument types that hold stand-in and dispatch to one method."""
function reached(code::Core.CodeInfo, instance::Core.MethodInstance)::Vector{Type}
    parameters = CC.sptypes_from_meth_instance(instance)
    found = Type[]
    for statement in code.code
        call = statement_call(statement)
        isnothing(call) && continue
        types = Any[CC.widenconst(code_argextype(argument, code, parameters)) for argument in call.args]
        call_signature = Tuple{types...}
        all(settled, types) && any(holds_stand_in, types) || continue
        matches = Base._methods_by_ftype(call_signature, 1, Base.get_world_counter())
        matches isa Vector && length(matches) == 1 && push!(found, call_signature)
    end
    return found
end

"""Method call `signature` dispatches to; stage keeps only signatures that dispatch to one method."""
dispatched(signature::Type)::Method = only(Base._methods_by_ftype(signature, 1, Base.get_world_counter())::Vector).method

include("Inference/failures.jl")

include("Inference/store.jl")

"""Marker of undefined field in `plain_digest` stream."""
struct UndefinedField end

"""Marker of struct that `plain_digest` stream wrote before, by its visit position: shared part counts once."""
struct SeenStruct
    position::Int
end

"""
Digest of `value` when number, character, string, symbol, bits value (enum), or immutable struct of those, tuples
included: data that inference or `@eval` loops of other files read. Other value gives `nothing`. Work stack and
leaf-only serializer: constant linked list can be deeper than call stack. Bits values come first: serializer calls
package `write` of primitive type, which can throw.
"""
function plain_digest(@nospecialize(value::Any))::Union{Nothing, String}
    stream, pending, seen, kept = IOBuffer(), Any[value], Dict{Ptr{Cvoid}, Int}(), Any[]
    while !isempty(pending)
        current = pop!(pending)
        if isprimitivetype(typeof(current))
            # Enum value, number and other bits type: pointer read calls no method on package type, whose `write` or
            # promotion would throw, change bytes or invalidate.
            serialize(stream, typeof(current))
            box = Base.RefValue(current)
            GC.@preserve box write(stream, unsafe_wrap(Array, Ptr{UInt8}(pointer_from_objref(box)), Core.sizeof(current)))
        elseif current isa Union{String, Symbol, UndefinedField}
            serialize(stream, current)
        elseif isstructtype(typeof(current)) && !ismutable(current)
            position = get(seen, heap_address(current), 0)
            if position > 0
                serialize(stream, SeenStruct(position))
                continue
            end
            push!(kept, current)
            seen[heap_address(current)] = length(kept)
            # Type, then fields in order (stack pops last push first): fixed field count keeps stream unambiguous.
            serialize(stream, typeof(current))
            for index in nfields(current):-1:1
                push!(pending, isdefined(current, index) ? getfield(current, index) : UndefinedField())
            end
        elseif current isa Union{Number, AbstractChar}
            # Mutable number of Base (`BigInt`): serializer writes its value.
            serialize(stream, current)
        else
            return nothing
        end
    end
    return bytes2hex(sha256(take!(stream)))
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
    # Tuple type with `Vararg` has no field count: its parameters, in `value`, are its layout.
    isstructtype(bare) && !isnothing(Base.datatype_fieldcount(bare)) && for index in 1:fieldcount(bare)
        push!(layout, fieldname(bare, index), fieldtype(bare, index))
    end
    return digest(layout)
end

"""
Shape text of constant `value`: layout for type (`type_layout`), name for function or module, value digest for plain
value (`plain_digest`), else type. Inference reads constants (`const op = +`).
"""
function constant_text(@nospecialize(value::Any))::String
    # Closure value would serialize its methods with their lines; name is stable.
    value isa Union{Function, Module} && return "$(parentmodule(value)).$(nameof(value))"
    value isa Type && return type_layout(value)
    text = plain_digest(value)
    return isnothing(text) ? digest(typeof(value)) : text
end

"""
Package shape that method store key hashes (`architecture.md`, Method store): text of each file that holds method whose
signature names no package type (piracy), and id of each method on callee of other module or on any callee (`foreign_callee`).
Walk sees no edge to them: call in Base code can reach them.
"""
function shape(package::PackageFacts)::Vector{String}
    modules, named, parts = Set(package.modules), IdDict{Any, Bool}(), String[]
    for site in Iterators.flatten((package.methods, package.keyword_bodies))
        if !names_package!(named, site.method.sig, modules)
            push!(parts, "piracy $(site.file.path) $(bytes2hex(sha256(site.file.text)))")
        elseif foreign_callee(site.method.sig, modules)
            push!(parts, "foreign $(site.file.path) $(method_id(site.method))")
        end
    end
    return unique!(parts)
end

"""
Meaning of each package name store entries read (`architecture.md`, Method store): of callee (`package_callee`), digest
of ids of its package methods; of type, its layout (`type_layout`). Name absent here means `""`: call of name with no
method, or type that edit removed.
"""
function meanings(package::PackageFacts)::Dict{String, String}
    modules, ids = Set(package.modules), Dict{String, Vector{String}}()
    for site in Iterators.flatten((package.methods, package.keyword_bodies))
        name = package_callee(dispatch_name(site.method.sig), modules)
        isnothing(name) || push!(get!(Vector{String}, ids, name), method_id(site.method))
    end
    found = Dict(name => short(digest(sort!(methods))) for (name, methods) in ids)
    for mod in package.modules, name in names(mod; all = true)
        (isdefined(mod, name) && isconst(mod, name)) || continue
        value = getglobal(mod, name)
        value isa Type && (found["type $mod.$name"] = short(type_layout(value)))
    end
    return found
end

"""Step for queued signature: seen before, over `LIMIT`, crashed earlier run, served by store, or inferred."""
@enumx Step seen over_limit crashed stored inferred

"""Queued signatures per thread in one wave: wave keeps compiler frame of each inference until its merge."""
const WAVE = 4

"""
Step for `method` on `call_signature`, with store key and store entry; marks signature seen and counts it. Calls can
reach one method with ever new types (`f(x) = f((x,))`), so reached signatures stop at limit.
"""
function next_step!(seen::AbstractSet{Tuple{Method, Type}}, counts::AbstractDict{Method, <:Integer}, method::Method, call_signature::Type, store::Union{Nothing, Store}, journal::Union{Nothing, Journal}, hashes::AbstractDict{String, String}, index::AbstractDict{String, Method}, memo::Union{Nothing, StoreMemo})::Tuple{Step.T, String, Union{Nothing, Entry}}
    (method, call_signature) in seen && return Step.seen, "", nothing
    push!(seen, (method, call_signature))
    counts[method] = get(counts, method, 0) + 1
    counts[method] > LIMIT && return Step.over_limit, "", nothing
    key = isnothing(store) ? "" : entry_key(method, call_signature)
    isnothing(journal) || !(key in journal.crashed) || return Step.crashed, key, nothing
    entry = isnothing(store) ? nothing : valid_entry(store, key, hashes, index, something(memo), journal)
    return isnothing(entry) ? Step.inferred : Step.stored, key, entry
end

"""
`infer` of each `(method, signature, key)` in `jobs`, in order, with verdicts on its calls that never return
(`call_verdicts!`) and on whether it ends (`endless_verdict`), each with compiler edges. Suspect of crash `journal` runs alone, first; so does each job of one-job wave or one-thread run.
Others run on all threads at once; `helpers` caches throw-helper verdicts across them (`HelperVerdicts`), and package `files` decide own calls.
"""
function infer_wave!(journal::Union{Nothing, Journal}, jobs::AbstractVector{<:Tuple{Method, Type, String}}, helpers::HelperVerdicts, files::AbstractDict{String, SyntaxFile})::Vector{Union{Nothing, Tuple{Output, Vector{CallVerdict}, Vector{Any}, Union{Nothing, Confidence.T}, Vector{Any}}}}
    solo = length(jobs) == 1 || Threads.nthreads(:default) == 1
    alone = [solo || (!isnothing(journal) && key in journal.suspects) for (_, _, key) in jobs]
    single = Dict(position => journaled_infer!(journal, helpers, files, jobs[position]..., true) for position in findall(alone))
    shared = Dict(position => Threads.@spawn(journaled_infer!(journal, helpers, files, jobs[position]..., false)) for position in findall(!, alone))
    return Union{Nothing, Tuple{Output, Vector{CallVerdict}, Vector{Any}, Union{Nothing, Confidence.T}, Vector{Any}}}[alone[position] ? single[position] : fetch(shared[position]) for position in eachindex(jobs)]
end

"""
`infer` of `method` on `signature`, verdicts on its calls that never return (`call_verdicts!`) and on whether it ends
(`endless_verdict`), between start and
finish records of store `key` in crash `journal`; `alone` when no other inference runs beside it.
"""
function journaled_infer!(journal::Union{Nothing, Journal}, helpers::HelperVerdicts, files::AbstractDict{String, SyntaxFile}, method::Method, signature::Type, key::String, alone::Bool)::Union{Nothing, Tuple{Output, Vector{CallVerdict}, Vector{Any}, Union{Nothing, Confidence.T}, Vector{Any}}}
    isnothing(journal) || record!(journal, start_record(key, method_label(method), alone))
    result = infer(method, signature)
    verdicts = isnothing(result) ? nothing : (result, call_verdicts!(helpers, method, signature, result, files)..., endless_verdict(method, signature, result)...)
    isnothing(journal) || record!(journal, finish_record(key, nothing))
    return verdicts
end

"""
Run of inference stage: facts, blind spots, units (typed code of signatures it inferred, and units store served), and
store of entries it used.
Signatures: stand-in signatures of package methods in `files` and their keyword bodies, then those their calls reach. Blind spots: signatures over
`LIMIT`, argument without stand-in, inference that gives no code, untyped method no call reaches, call that fails on
stand-in only. `store` serves entries whose files are unchanged; `nothing` turns store off and gives no store.
`journal` records each inference; key that crashed earlier run gets blind spot and no inference. Journal needs store.
"""
function infer_package(package::PackageFacts, files::AbstractVector{SyntaxFile}, store::Union{Nothing, Store}, journal::Union{Nothing, Journal})::Tuple{InferenceFacts, Vector{BlindSpot}, Units, Union{Nothing, Store}}
    isnothing(journal) || !isnothing(store) || throw(ArgumentError("crash journal records store keys, so it needs method store"))
    structs = struct_stand_ins(Type[site.type for site in package.structs])
    spots = BlindSpot[]
    # Each signature notes whether stand-in signatures gave it, or call reached it.
    pending, skipped = Tuple{MethodSite, Type, Bool}[], MethodSite[]
    # Methods with signature inference skipped or failed, or code that tests type: results miss some argument types.
    incomplete = Set{Method}()
    # Keyword body gets stand-ins for declared keyword types; wrapper passes default values only.
    bodies = Set(site.method for site in package.keyword_bodies)
    for site in Iterators.flatten((package.methods, package.keyword_bodies))
        untyped(site, site.method in bodies) && (push!(skipped, site); continue)
        found = method_signatures(site.method, structs)
        found.over_limit && (push!(spots, BlindSpot("signatures over limit", site.span)); push!(incomplete, site.method))
        # Explicit `::Any` and unbounded type variable hide nothing compiler knows, so only narrower declared types count.
        any(position -> Facts.argument_type(site.method, position) != Any, found.bare) && push!(spots, BlindSpot("argument without stand-in", site.span))
        append!(pending, ((site, signature, true) for signature in found.signatures))
    end
    by_path = Dict(file.path => file for file in files)
    lines = Dict(file.path => Package.Lines(file) for file in files)
    sites = Dict(site.method => site for site in Iterators.flatten((package.methods, package.keyword_bodies)))
    hashes = Dict(file.path => bytes2hex(sha256(file.text)) for file in files)
    used, modules, helpers = isnothing(store) ? nothing : Store(), Set(package.modules), HelperVerdicts()
    index, ids = isnothing(store) ? (Dict{String, Method}(), IdDict{Method, String}()) : method_index(by_path)
    memo = isnothing(store) ? nothing : StoreMemo(package, ids)
    typed, stored, seen, counts, coded = TypedCode[], StoredUnit[], Set{Tuple{Method, Type}}(), Dict{Method, Int}(), Set{Method}()
    failing, gaps, settled, disrupting, narrowing = FailingCall[], BlindSpot[], Set{Tuple{Method, Int}}(), Disruption[], NarrowingLoss[]
    hard, iterates, observed, declared = HardArray[], StatefulIterate[], IdDict{Method, Vector{Tuple{Type, Type}}}(), IdDict{Method, Union{Nothing, Core.CodeInfo}}()
    looping = IdDict{Method, Tuple{MethodSite, Confidence.T, Vector{Pair{Span, Type}}}}()
    while !isempty(pending)
        # Queue head is one wave; merge queues reached calls behind rest, in order one queue would give.
        wave = splice!(pending, 1:min(length(pending), WAVE * Threads.nthreads(:default)))
        steps = Tuple{Step.T, String, Union{Nothing, Entry}}[next_step!(seen, counts, site.method, call_signature, store, journal, hashes, index, memo) for (site, call_signature, _) in wave]
        inferring = [position for (position, (step, _, _)) in enumerate(steps) if step == Step.inferred]
        outputs = Dict(zip(inferring, infer_wave!(journal, Tuple{Method, Type, String}[(wave[position][1].method, wave[position][2], steps[position][2]) for position in inferring], helpers, by_path)))
        for (position, (site, call_signature, stand_in)) in enumerate(wave)
            step, key, entry = steps[position]
            step == Step.seen && continue
            step == Step.over_limit && (push!(spots, BlindSpot("signatures over limit", site.span)); push!(incomplete, site.method); continue)
            step == Step.crashed && (push!(spots, BlindSpot("inference crashed process", site.span)); push!(incomplete, site.method); continue)
            if step == Step.inferred
                # Merge reads more code: generator can still abort, so merge has its own journal records.
                isnothing(journal) || record!(journal, start_record(key, method_label(site.method), true))
                edges = Any[]
                result = outputs[position]
                inferred = if isnothing(result)
                    Inferred(Union{}, Tuple{Type, Type}[], Type[], Pair{Int, Union{FailingCall, BlindSpot}}[], nothing, Pair{Span, Type}[], false, false, Disruption[], HardArray[], NarrowingLoss[], StatefulIterate[])
                else
                    (instance, code, returned, frame_edges, flow, frame), verdicts, verdict_edges, endless, endless_edges = result
                    append!(edges, frame_edges, call_signatures(code, instance))
                    nodes = statement_nodes(code, mappings(code, instance, site), site.file)
                    opted = [position for position in 1:(site.method.nargs - 1) if explicit_any(site, code.slotnames[position + 1])]
                    provenance = argument_provenance(site.method, call_signature, stand_in, opted)
                    push!(typed, TypedCode(site, call_signature, code, returned, spans(code, instance, site, lines[site.file.path].starts, nodes)..., frame, provenance, Int[]))
                    # Failures need unit spans; cuts need failures.
                    failures, stand_in_only = call_failures(last(typed), verdicts)
                    append!(edges, verdict_edges, endless_edges)
                    append!(last(typed).cuts, cuts!(declared, site.method, call_signature, code, stand_in_only))
                    changes, branch = Widening.changes!(edges, instance, code)
                    constructions, array_branch = HardArrays.changes!(edges, instance, code)
                    lost = narrowings(last(typed), nodes, Narrowing.losses(code, flow, CC.sptypes_from_meth_instance(instance)))
                    called = package_calls(code, instance, modules, by_path)
                    stuck = isnothing(endless) ? Pair{Span, Type}[] : [last(typed).spans[index] => signature for (index, signature, result) in called if result === Union{}]
                    Inferred(
                        returned, [(signature, result) for (_, signature, result) in called], reached(code, instance), failures, endless, stuck, true,
                        Widening.type_branch(code, CC.sptypes_from_meth_instance(instance)), disruptions(last(typed), instance, nodes, changes, branch),
                        hard_arrays(last(typed), instance, nodes, constructions, array_branch), lost, stateful_iterates(last(typed), instance, nodes),
                    )
                end
                entry = isnothing(used) ? nothing : entry!(something(memo), site, call_signature, inferred, edges, by_path, hashes)
                isnothing(journal) || record!(journal, finish_record(key, entry))
            else
                inferred = deserialize(IOBuffer(entry.inferred))::Inferred
                push!(stored, StoredUnit(site, call_signature, entry.effects, length(typed)))
            end
            isnothing(used) || isnothing(entry) || (used[key] = entry)
            inferred.coded || (push!(spots, BlindSpot("inference gave no code", site.span)); push!(incomplete, site.method); continue)
            # Stand-ins model no `BigFloat`, so branch on type can return what no stand-in saw.
            inferred.tests_type && push!(incomplete, site.method)
            push!(get!(Vector{Tuple{Type, Type}}, observed, site.method), (call_signature, inferred.returned))
            for (call_signature, result) in inferred.calls
                push!(get!(Vector{Tuple{Type, Type}}, observed, dispatched(call_signature)), (call_signature, result))
            end
            push!(coded, site.method)
            # Declared signature decides `definite`, so units of one method agree on confidence.
            isnothing(inferred.endless) || unique!(append!(get!(() -> (site, something(inferred.endless), Pair{Span, Type}[]), looping, site.method)[3], inferred.endless_calls))
            # Package methods are those analyzed files define; others (Base) stay outside.
            for signature in inferred.reached
                method = dispatched(signature)
                file = get(by_path, string(method.file), nothing)
                isnothing(file) && continue
                push!(pending, (get!(() -> Package.method_site(method, file, lines[file.path]), sites, method), signature, false))
            end
            for (index, failure) in inferred.failures
                (site.method, index) in settled && continue
                if failure isa BlindSpot
                    push!(gaps, failure)
                else
                    push!(settled, (site.method, index))
                    push!(failing, failure)
                end
            end
            append!(disrupting, inferred.disruptions)
            append!(hard, inferred.hard_arrays)
            append!(narrowing, inferred.narrowings)
            append!(iterates, inferred.stateful_iterates)
        end
    end
    append!(spots, BlindSpot("untyped method no call reaches", site.span) for site in skipped if !(site.method in coded))
    # One finding per weak value: escape before intermediate, definite before possible.
    sort!(disrupting; by = disruption -> (disruption.exit == Exit.intermediate, disruption.confidence == Confidence.possible))
    sort!(hard; by = array -> (array.exit == Exit.intermediate, array.confidence == Confidence.possible))
    facts = InferenceFacts(failing, endless_cycles(looping), unique!(disruption -> disruption.span, disrupting), unique!(array -> array.span, hard), unique!(lost -> lost.test, narrowing), annotation_guesses(package, observed, incomplete), unique!(call -> call.span, iterates))
    return facts, unique!(append!(spots, gaps)), Units(typed, incomplete, stored), used
end

end
