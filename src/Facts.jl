"""
Fact types and query API. Only module rule code may import.

Analyses build facts once per run; rules read them through this module and return `Finding`s.
`SyntaxNode` `==` and `hash` walk whole subtree: compare nodes with `===`, key collections by `objectid`.
"""
module Facts

using Argus: Argus, @pattern, Pattern, BindingSet, syntax_match
using EnumX: @enumx
using JuliaSyntax: JuliaSyntax as JS, SyntaxNode, Kind
using ReadOnlyArrays: ReadOnlyVector

export Precision, Tier, Confidence, Group, Stage, Role, BindingKind, TestDeps
export Span, Label, Edit, Fix, Finding, BlindSpot, RuleEntry
export SyntaxFile, SyntaxNode, FactSet, IndexedPattern, Match, BindingSite, Ban, MethodSite, StructSite, PackageFacts, ExternalFacts, Extension, ProjectFacts
export @pattern, matches, binding, span, source, all_nodes, forms, leaves, children_of, kind_name
export name_span, argument_type, call_text, finding, replace_fix, manual_fix, identifier_name, base_name, base_macro, infix_operator, parent_of, ancestors, descendants, call_head, leaf_value
export definition_name, signature, argument_annotations, resolve_type, struct_fields, include_calls, include_target, normalized_source, macro_name, macro_span
export takes_docstring, comment_lines_above, comments_in, discarded, literal

"""Span precision: `exact` bytes, or `line` when only line is known."""
@enumx Precision exact line
"""Fix risk to callers; one setting picks highest tier applied automatically."""
@enumx Tier safe likely breaking manual
"""`definite`: problem exists. `possible`: compiler cannot resolve doubt either."""
@enumx Confidence definite possible
"""User-facing rule group."""
@enumx Group correctness performance composability readability
"""Analysis stage that computes facts rule reads, in pipeline order."""
@enumx Stage syntax package scope inference effects lifecycle external
"""File role: `package` module code precompiles; `script` code (tests, docs, scripts) runs each time it loads."""
@enumx Role package script
"""Name binding site: function `parameter`, `assignment` target, `loop` variable, `definition` name, struct `field`."""
@enumx BindingKind parameter assignment loop definition field
"""Where package lists test dependencies: `[targets].test` of Project.toml, test/Project.toml, or nowhere."""
@enumx TestDeps target project none

"""Byte range `first_byte:last_byte` of `file`, 1-based and inclusive."""
struct Span
    file::String
    first_byte::Int
    last_byte::Int
    precision::Precision.T
end

"""Span with text rendered under it."""
struct Label
    span::Span
    text::String
end

"""Replace bytes of `span` with `replacement`."""
struct Edit
    span::Span
    replacement::String
end

"""Fix shown under finding. `manual` fix carries no edits."""
struct Fix
    text::String
    edits::Vector{Edit}
    tier::Tier.T
end

"""One problem at one place. `message` is headline; `why` explains harm."""
struct Finding
    rule::Symbol
    kind::Symbol
    confidence::Confidence.T
    message::String
    primary::Label
    causes::Vector{Label}
    why::String
    fix::Union{Fix, Nothing}
end

"""Site Corset skipped though compiler resolves it; coverage line counts it by `cause`."""
struct BlindSpot
    cause::String
    span::Span
end

"""Registry entry: rule metadata plus pure function `run(facts::FactSet)::Vector{Finding}`."""
struct RuleEntry
    name::Symbol
    group::Group.T
    footguns::Vector{Int}
    stage::Stage.T
    run::Function
end

"""Identifier node that binding site binds, and site kind."""
struct BindingSite
    name::SyntaxNode
    kind::BindingKind.T
end

"""
Parsed source file (`syntax` stage facts): role, lossless tree, comment byte ranges, and code nodes indexed by kind.
Index keeps forms (inner nodes) apart from leaves, since quoted operators like `:(=)` are leaves of form kinds.
Index skips quoted code outside interpolation and macro arguments with `{}` (`Syntax.walk`); tree walks see both.
`groups` maps node to bytes of grouping parentheses that wrap only it (`Syntax.groups`).
`parse_errors` label each JuliaSyntax parse error; tree holds recovered code there.
`bindings` lists names code binds, in kind order (`Syntax.binding_sites`).
"""
struct SyntaxFile
    path::String
    text::String
    role::Role.T
    tree::SyntaxNode
    forms::Dict{Kind, Vector{SyntaxNode}}
    leaves::Dict{Kind, Vector{SyntaxNode}}
    comments::Vector{UnitRange{Int}}
    groups::IdDict{SyntaxNode, UnitRange{Int}}
    parse_errors::Vector{Label}
    bindings::Vector{BindingSite}
end

"""
Argus pattern plus filter on root nodes it can match: kind, then call head for `call` roots.
`nothing` filter means pattern variable sits at root; head set `nothing` means any head.
"""
struct IndexedPattern
    pattern::Pattern
    roots::Union{Nothing, Dict{Kind, Union{Nothing, Set{String}}}}
end

"""`pattern` indexed by root alternatives, so matcher tries only candidate nodes."""
function IndexedPattern(pattern::Pattern)::IndexedPattern
    alternatives = root_alternatives(pattern.src)
    any(node -> startswith(kind_name(node), "~"), alternatives) && return IndexedPattern(pattern, nothing)
    roots = Dict{Kind, Union{Nothing, Set{String}}}()
    for node in alternatives
        kind, head = JS.kind(node), call_head(node)
        previous = get(roots, kind, Set{String}())
        roots[kind] = isnothing(head) || isnothing(previous) ? nothing : push!(previous, head)
    end
    return IndexedPattern(pattern, roots)
end

"""Indexed pattern from Argus pattern `text`, as config writes it; bad pattern throws `ArgumentError`."""
function parse_pattern(text::String)::IndexedPattern
    expression = try
        Meta.parse(text; raise = true)
    catch error
        error isa Meta.ParseError || rethrow()
        throw(ArgumentError(sprint(showerror, error)))
    end
    isnothing(expression) && throw(ArgumentError("pattern is empty"))
    Meta.isexpr(expression, :incomplete) && throw(ArgumentError("pattern ends early: $(repr(text))"))
    try
        return IndexedPattern(Pattern(Argus.SyntaxPatternNode(expression)))
    catch error
        error isa Argus.SyntaxError || rethrow()
        throw(ArgumentError(sprint(showerror, error)))
    end
end

"""Project ban from config: Argus pattern, or name regex that must match whole name; text as written, and reason."""
struct Ban
    text::String
    target::Union{IndexedPattern, Regex}
    reason::String
end

"""
Method package code defines, in analyzed `file`. `node` is its definition node, when exactly one definition of that
name starts on method line; `nothing` otherwise (`@eval` loops, macro output), and `span` then has line precision.
"""
struct MethodSite
    method::Method
    file::SyntaxFile
    node::Union{Nothing, SyntaxNode}
    span::Span
end

"""Struct package code defines, as written (`UnionAll` for parametric struct), and its `struct` form in analyzed `file`."""
struct StructSite
    type::Type
    file::SyntaxFile
    node::SyntaxNode
end

"""Package extension: name, file Julia loads (`ext/<name>.jl` or `ext/<name>/<name>.jl`), and trigger packages."""
struct Extension
    name::String
    file::String
    triggers::Vector{Base.PkgId}
end

"""
Project.toml facts of package (`syntax` stage, read before load): name, uuid (`nothing` when absent or invalid), root
directory, module file, direct dependencies, extensions by name, where tests list dependencies, and test dependencies
other than direct ones, by name.
"""
struct ProjectFacts
    name::String
    uuid::Union{Nothing, Base.UUID}
    root::String
    entry::String
    deps::Vector{Base.PkgId}
    extensions::Vector{Extension}
    test_deps::TestDeps.T
    tests::Vector{Base.PkgId}
end

"""
Loaded package (`package` stage facts): package modules (root, submodules, loaded extensions; root first), values
public names reach, and sites of methods and structs package modules define in analyzed files.
`methods` keeps methods later definitions replaced; `overwrites` pairs each (earlier, later) by same signature.
"""
struct PackageFacts
    modules::Vector{Module}
    public::Base.IdSet{Any}
    methods::Vector{MethodSite}
    overwrites::Vector{Tuple{MethodSite, MethodSite}}
    structs::Vector{StructSite}
end

"""
External tool output on loaded package (`external` stage facts): pairs of package method sites `Test.detect_ambiguities`
reports, earlier definition first.
"""
struct ExternalFacts
    ambiguities::Vector{Tuple{MethodSite, MethodSite}}
end

"""
Facts of one run: parsed files, entry files Julia loads directly (empty for directory walk, where any file may be included),
project bans from config, enclosing package project (`nothing` outside project with `name`), loaded package
(`nothing` for scripts, nameless projects, failed load, or run without package rules), and external tool output
(`nothing` without loaded package, or run without `external` rules).
"""
struct FactSet
    files::Vector{SyntaxFile}
    entries::Vector{String}
    bans::Vector{Ban}
    project::Union{Nothing, ProjectFacts}
    package::Union{Nothing, PackageFacts}
    external::Union{Nothing, ExternalFacts}
end

"""Root nodes of pattern, with `~or` alternatives flattened."""
root_alternatives(node::JS.TreeNode)::Vector{Any} =
    kind_name(node) == "~or" ? reduce(vcat, map(root_alternatives, JS.children(node))) : Any[node]

"""
Base function name call `node` calls, read as written (operator for infix call): `"error"` for `error(…)` and `Base.error(…)`.
`nothing` for other nodes, computed callee, and function of module outside `BASE_MODULES`.
"""
function call_head(node::JS.TreeNode)::Union{Nothing, String}
    kind_name(node) == "call" || return nothing
    return base_name(JS.children(node)[JS.is_infix_op_call(node) ? 2 : 1])
end

"""Functions that load file into calling module: Base `include`, Revise `includet`."""
const INCLUDES = ("include", "includet")

"""Calls of `file` that load another file."""
include_calls(file::SyntaxFile)::Vector{SyntaxNode} = filter(call -> call_head(call) in INCLUDES, forms(file, "call"))

"""Absolute path include `call` in `file` loads; `nothing` when path is computed."""
function include_target(file::SyntaxFile, call::SyntaxNode)::Union{Nothing, String}
    parts = path_parts(file, children_of(call)[end])
    return isnothing(parts) ? nothing : normpath(joinpath(dirname(file.path), parts...))
end

"""Path pieces of `node`: string literal, `raw` string, `@__DIR__`, or `joinpath` of those; `nothing` for anything else."""
function path_parts(file::SyntaxFile, node::SyntaxNode)::Union{Nothing, Vector{String}}
    pieces = children_of(node)
    kind_name(node) == "string" && length(pieces) == 1 && kind_name(pieces[1]) == "String" && return [leaf_value(pieces[1])]
    kind_name(node) == "macrocall" && leaf_value(pieces[1]) == "@raw_str" && return path_parts(file, pieces[2])
    kind_name(node) == "macrocall" && leaf_value(pieces[1]) == "@__DIR__" && return [dirname(file.path)]
    call_head(node) == "joinpath" || return nothing
    parts = [path_parts(file, piece) for piece in pieces[2:end]]
    return any(isnothing, parts) ? nothing : reduce(vcat, parts; init = String[])
end

"""Name of node kind as string; Argus pattern forms start with `~`."""
kind_name(node::JS.TreeNode)::String = string(JS.kind(node))

"""Successful match of pattern at `node` with its pattern variable bindings."""
struct Match
    node::SyntaxNode
    bindings::BindingSet
end

"""Forms (inner nodes) of `file` whose kind is named `name` (`"="`, `"catch"`), in source order."""
forms(file::SyntaxFile, name::String)::Vector{SyntaxNode} = get(file.forms, Kind(name), SyntaxNode[])

"""Leaves of `file` whose kind is named `name` (`"Identifier"`, `"Integer"`), in source order."""
leaves(file::SyntaxFile, name::String)::Vector{SyntaxNode} = get(file.leaves, Kind(name), SyntaxNode[])

"""Every node of `file`: forms, then leaves."""
all_nodes(file::SyntaxFile)::Vector{SyntaxNode} = [node for index in (file.forms, file.leaves) for nodes in values(index) for node in nodes]

"""Every match of `indexed` in `file`, in source order. Tries only nodes whose kind and call head pattern root can take."""
function matches(file::SyntaxFile, indexed::IndexedPattern)::Vector{Match}
    found = Match[]
    if isnothing(indexed.roots)
        foreach(node -> try_match!(found, indexed, node), all_nodes(file))
    else
        for (kind, heads) in indexed.roots, index in (file.forms, file.leaves), node in get(index, kind, SyntaxNode[])
            isnothing(heads) || call_head(node) in heads || continue
            try_match!(found, indexed, node)
        end
    end
    return sort!(found; by = match -> JS.first_byte(match.node))
end

"""Push match of `indexed` at `node` to `found` when pattern matches."""
function try_match!(found::Vector{Match}, indexed::IndexedPattern, node::SyntaxNode)::Nothing
    result = syntax_match(indexed.pattern, node)
    result isa BindingSet && push!(found, Match(node, result))
    return nothing
end

"""Syntax node bound to pattern variable `name` in `match`."""
binding(match::Match, name::Symbol)::SyntaxNode = match.bindings[name].src

"""`range` of bytes in `text` without surrounding whitespace."""
function trimmed(text::String, range::UnitRange{Int})::UnitRange{Int}
    bytes = codeunits(text)
    first, last = range.start, range.stop
    while first < last && bytes[first] in (UInt8(' '), UInt8('\t'), UInt8('\n'), UInt8('\r'))
        first += 1
    end
    while last > first && bytes[last] in (UInt8(' '), UInt8('\t'), UInt8('\n'), UInt8('\r'))
        last -= 1
    end
    return first:last
end

"""Byte range of `node` in `text` without surrounding whitespace; infix nodes start at leading trivia."""
trimmed_bytes(text::String, node::SyntaxNode)::UnitRange{Int} = trimmed(text, JS.first_byte(node):JS.last_byte(node))

"""Exact span of `node` in `file`."""
function span(file::SyntaxFile, node::SyntaxNode)::Span
    bytes = trimmed_bytes(file.text, node)
    return Span(file.path, first(bytes), last(bytes), Precision.exact)
end

"""
Source text of `node` in `file` with grouping parentheses that wrap only it; safe to paste as operand.
Assignment pasted as call argument reads as keyword: `f((x = 1))` means `f(; x = 1)`.
"""
function source(file::SyntaxFile, node::SyntaxNode)::String
    bytes = get(() -> trimmed_bytes(file.text, node), file.groups, node)
    return file.text[first(bytes):thisind(file.text, last(bytes))]
end

"""Span of name of macro call `node` as written; `MacroName` leaf starts after its `@`, string macro name (`raw`) has none."""
function macro_span(file::SyntaxFile, node::SyntaxNode)::Span
    name = span(file, children_of(node)[1])
    return kind_name(children_of(node)[1]) == "MacroName" ? Span(name.file, name.first_byte - 1, name.last_byte, name.precision) : name
end

"""Name of macro call `node` as written: `"@async"`, `"Threads.@async"`, `"raw"` for `raw"…"`."""
macro_name(file::SyntaxFile, node::SyntaxNode)::String = (name = macro_span(file, node); file.text[name.first_byte:thisind(file.text, name.last_byte)])

"""Name of identifier `node`; `nothing` for other kinds."""
identifier_name(node::JS.TreeNode)::Union{Nothing, String} = kind_name(node) == "Identifier" ? string(node.val) : nothing

"""Module paths whose names count as Base names, as written before `.`: `Base.error`, `Core.Task`, `Threads.@spawn`."""
const BASE_MODULES = ("Base", "Core", "Threads", "Base.Threads")

"""Dotted module path `node` writes: `"Base.Threads"` for `Base.Threads`; `nothing` for other forms."""
function module_path(node::JS.TreeNode)::Union{Nothing, String}
    kind_name(node) == "." || return identifier_name(node)
    outer, inner = module_path(JS.children(node)[1]), identifier_name(JS.children(node)[end])
    return isnothing(outer) || isnothing(inner) ? nothing : "$outer.$inner"
end

"""Name `node` gives Base binding, read as written: `"NaN"` for `NaN` and `Base.NaN`; `nothing` for name of other module."""
function base_name(node::JS.TreeNode)::Union{Nothing, String}
    kind_name(node) == "." || return identifier_name(node)
    return module_path(JS.children(node)[1]) in BASE_MODULES ? identifier_name(JS.children(node)[end]) : nothing
end

"""
Base macro that macro call `node` names, read as written: `"@spawn"` for `@spawn`, `Threads.@spawn` and `Base.Threads.@spawn`.
`nothing` for macro of other module, such as `Mine.@spawn`, and for nodes other than macro calls.
"""
function base_macro(node::SyntaxNode)::Union{Nothing, String}
    kind_name(node) == "macrocall" || return nothing
    name = children_of(node)[1]
    kind_name(name) == "." || return leaf_value(name)
    return module_path(children_of(name)[1]) in BASE_MODULES ? leaf_value(children_of(name)[end]) : nothing
end

"""Operator of infix call `node`, dot included: `"=="` for `a == b`, `".=="` for `a .== b`; `nothing` for other nodes."""
function infix_operator(node::SyntaxNode)::Union{Nothing, String}
    kind_name(node) in ("call", "dotcall") && JS.is_infix_op_call(node) || return nothing
    name = identifier_name(children_of(node)[2])
    return kind_name(node) == "dotcall" && !isnothing(name) ? "." * name : name
end

"""Parent of `node`; `nothing` at root."""
parent_of(node::SyntaxNode)::Union{Nothing, SyntaxNode} = node.parent

"""Strict ancestors of `node`, nearest first."""
function ancestors(node::SyntaxNode)::Vector{SyntaxNode}
    found = SyntaxNode[]
    current = node.parent
    while !isnothing(current)
        push!(found, current)
        current = current.parent
    end
    return found
end

"""`node` and every descendant, parents first."""
function descendants(node::SyntaxNode)::Vector{SyntaxNode}
    found = SyntaxNode[node]
    for child in children_of(node)
        append!(found, descendants(child))
    end
    return found
end

"""Value of leaf `node` as string (`"@ccall"` for macro name); `nothing` for inner node."""
leaf_value(node::SyntaxNode)::Union{Nothing, String} = JS.is_leaf(node) ? string(node.val) : nothing

"""Children of leaf."""
const NO_CHILDREN = ReadOnlyVector(SyntaxNode[])

"""Children of `node`, read-only and without copy; empty for leaf."""
children_of(node::SyntaxNode)::ReadOnlyVector{SyntaxNode, Vector{SyntaxNode}} =
    JS.is_leaf(node) ? NO_CHILDREN : ReadOnlyVector(JS.children(node))

"""Name node of definition `node` (function, macro, struct, module): strips `where`, result type, arguments, type parameters, supertype."""
function definition_name(node::SyntaxNode)::SyntaxNode
    head = children_of(node)[1]
    while kind_name(head) in ("where", "::", "call", "curly", "<:") && !isempty(children_of(head))
        head = children_of(head)[1]
    end
    return head
end

"""Signature call of function definition `node` under `where` and result type, and whether result has type; `nothing` for anonymous function."""
function signature(definition::SyntaxNode)::Union{Nothing, Tuple{SyntaxNode, Bool}}
    head, typed = children_of(definition)[1], false
    while kind_name(head) in ("where", "::") && length(children_of(head)) == 2
        typed |= kind_name(head) == "::"
        head = children_of(head)[1]
    end
    return kind_name(head) == "call" ? (head, typed) : nothing
end

"""Type annotation nodes of argument `node` of signature call, through default value, splat and keyword group."""
function argument_annotations(node::SyntaxNode)::Vector{SyntaxNode}
    kind = kind_name(node)
    kind == "parameters" && return reduce(vcat, map(argument_annotations, children_of(node)); init = SyntaxNode[])
    kind in ("=", "kw", "...") && return argument_annotations(children_of(node)[1])
    return kind == "::" ? [children_of(node)[end]] : SyntaxNode[]
end

"""Type name `node` (identifier or dotted name) of `file` refers to from `mod`; `nothing` for other syntax or value."""
function resolve_type(mod::Module, file::SyntaxFile, node::SyntaxNode)::Union{Nothing, Type}
    kind_name(node) in ("Identifier", ".") || return nothing
    value = mod
    for part in split(source(file, node), '.')
        value isa Module && isdefined(value, Symbol(part)) || return nothing
        value = getglobal(value, Symbol(part))
    end
    return value isa Type ? value : nothing
end

"""Span of function name at method `site`; whole line when site has no definition node."""
name_span(site::MethodSite)::Span = isnothing(site.node) ? site.span : span(site.file, definition_name(site.node))

"""
Type of argument `position` of `method`, wrapped in signature `where`: element type for `Vararg`, bound for type variable.
`nothing` when method has no such argument.
"""
function argument_type(method::Method, position::Int)::Union{Nothing, Type}
    parameters = Base.unwrap_unionall(method.sig).parameters
    length(parameters) > position || return nothing
    # Julia reduces `T where T <: Walk` to `Walk`, and drops type variables argument does not use.
    return Base.rewrap_unionall(Base.unwrapva(parameters[position + 1]), method.sig)
end

"""Call of `name` with argument types of tuple type `signature` after callee, as call writes it: `area(::Int64, ::T) where T<:Real`."""
function call_text(name::Symbol, signature::Type)::String
    variables, body = TypeVar[], signature
    while body isa UnionAll
        push!(variables, body.var)
        body = body.body
    end
    arguments = ("::" * (Base.isvarargtype(argument) ? "$(argument.T)..." : string(argument)) for argument in body.parameters[2:end])
    call = "$name($(join(arguments, ", ")))"
    return isempty(variables) ? call : "$call where {$(join(variables, ", "))}"
end

"""Field name nodes of struct definition `definition`, skipping inner constructors."""
function struct_fields(definition::SyntaxNode)::Vector{SyntaxNode}
    names = SyntaxNode[]
    for field in children_of(children_of(definition)[end])
        node = kind_name(field) == "=" ? children_of(field)[1] : field
        node = kind_name(node) == "::" ? children_of(node)[1] : node
        isnothing(identifier_name(node)) || push!(names, node)
    end
    return names
end

"""Whether docstring above `definition` attaches: statement at top level, in module body or in `begin` block."""
function takes_docstring(file::SyntaxFile, definition::SyntaxNode)::Bool
    statement = definition
    while !isnothing(parent_of(statement)) && kind_name(parent_of(statement)) == "macrocall"
        statement = parent_of(statement)
    end
    container = parent_of(statement)
    kind_name(container) == "toplevel" && return true
    kind_name(container) == "block" || return false
    kind_name(parent_of(container)) == "module" && return true
    # `begin` block: keyword comes before first statement; body blocks start at first statement.
    start = span(file, container).first_byte
    return startswith(SubString(file.text, start), "begin") && start < span(file, children_of(container)[1]).first_byte
end

"""Byte ranges of comment lines directly above byte `first` in `text`, top first; blank line ends block."""
function comment_lines_above(text::String, first::Int)::Vector{UnitRange{Int}}
    lines = UnitRange{Int}[]
    stop = something(findprev(==('\n'), text, prevind(text, first)), 0)
    while stop > 0
        start = something(findprev(==('\n'), text, prevind(text, stop)), 0) + 1
        content = strip(text[start:prevind(text, stop)])
        startswith(content, "#") && !startswith(content, "#=") && !startswith(content, "# corset:") || break
        pushfirst!(lines, start:(stop - 1))
        stop = start - 1
    end
    return lines
end

"""Comment byte ranges of `file` that start inside `bytes`, in source order."""
function comments_in(file::SyntaxFile, bytes::UnitRange{Int})::Vector{UnitRange{Int}}
    start = searchsortedfirst(file.comments, bytes; by = first)
    stop = searchsortedlast(file.comments, last(bytes):last(bytes); by = first)
    return file.comments[start:stop]
end

"""Kinds whose body block drops value of every statement."""
const DISCARDING = ("for", "while", "module", "finally")

"""
Whether value of statement `node` goes unused: any top-level statement, any statement of loop, module or `finally` body,
or non-last statement of other block. Struct body and `let` bindings hold no statements.
"""
function discarded(node::SyntaxNode)::Bool
    parent = parent_of(node)
    isnothing(parent) && return false
    kind_name(parent) == "toplevel" && return true
    kind_name(parent) == "block" || return false
    owner = parent_of(parent)
    kind_name(owner) == "struct" && return false
    kind_name(owner) == "let" && children_of(owner)[1] === parent && return false
    kind_name(owner) in DISCARDING && children_of(owner)[end] === parent && return true
    return children_of(parent)[end] !== node
end

"""Leaf kinds of number and boolean literals."""
const LITERAL_LEAVES = ("Integer", "Float", "Float32", "HexInt", "BinInt", "OctInt", "Bool")

"""Whether `node` is literal: string without interpolation, number, character, symbol, `nothing`, `true` or `false`."""
function literal(node::SyntaxNode)::Bool
    kind, children = kind_name(node), children_of(node)
    (kind in LITERAL_LEAVES || kind == "char") && return true
    kind == "string" && return all(child -> kind_name(child) == "String", children)
    kind == "quote" && return length(children) == 1 && kind_name(children[1]) == "Identifier"
    return identifier_name(node) == "nothing"
end

"""Tokens of layout: whitespace and comments."""
const LAYOUT_TOKENS = (JS.K"Whitespace", JS.K"NewlineWs", JS.K"Comment")

"""
Source of `node` for comparison: each layout run between tokens becomes one space, docstring drops, string contents stay exact.
Space stays significant: `[1 -2]` and `[1 - 2]` differ.
"""
function normalized_source(file::SyntaxFile, node::SyntaxNode)::String
    kind_name(node) == "doc" && return normalized_source(file, children_of(node)[end])
    text, pieces, gap = source(file, node), SubString{String}[], false
    for token in JS.tokenize(text)
        if JS.kind(token) in LAYOUT_TOKENS
            gap = !isempty(pieces)
        else
            gap && push!(pieces, SubString(" "))
            push!(pieces, SubString(text, Int(first(token.range)), thisind(text, Int(last(token.range)))))
            gap = false
        end
    end
    return join(pieces)
end

"""Finding of `rule` with primary label at `node` of `file`."""
function finding(
        rule::Symbol, file::SyntaxFile, node::SyntaxNode; kind::Symbol, confidence::Confidence.T, message::String,
        label::String, why::String, fix::Union{Fix, Nothing}, causes::Vector{Label} = Label[],
    )::Finding
    return Finding(rule, kind, confidence, message, Label(span(file, node), label), causes, why, fix)
end

"""Fix replacing `node` of `file` with `replacement`."""
replace_fix(file::SyntaxFile, node::SyntaxNode, replacement::String, tier::Tier.T)::Fix =
    Fix("replace with `$replacement`", [Edit(span(file, node), replacement)], tier)

"""Fix with no edits; shown, never applied."""
manual_fix(text::String)::Fix = Fix(text, Edit[], Tier.manual)

end
