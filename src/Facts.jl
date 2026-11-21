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

export Precision, Tier, Confidence, Group, Stage, Role, BindingKind, TestDeps, Weak, Exit, EffectKind
export Span, Label, Edit, Fix, Finding, BlindSpot, RuleEntry
export SyntaxFile, SyntaxNode, FactSet, IndexedPattern, Match, BindingSite, Ban, MethodSite, StructSite, PackageFacts, FailingCall, Disruption, HardArray, NarrowingLoss, AnnotationGuess, InferenceFacts, Step, Root, Place, Access, BlindAccess, UnguardedHold, Callee, CallFact, MethodEffects, EffectsFacts, InternalAccess, BareUsing, ExplicitImport, ExternalFacts, Extension, ProjectFacts
export @pattern, matches, binding, span, source, all_nodes, forms, leaves, children_of, kind_name
export name_span, tuple_parameters, argument_type, trait_type, call_text, finding, replace_fix, manual_fix, weak_words, weak_label, weak_fix, weak_causes, identifier_name, base_name, base_macro, infix_operator, parent_of, ancestors, descendants, call_head, leaf_value
export definition_name, signature, callee_node, call_arguments, argument_annotations, resolve_type, struct_fields, include_calls, include_target, normalized_source, macro_name, macro_span
export takes_docstring, comment_lines_above, comments_in, discarded, literal, line_start, owned_lines, line_deletion

"""Span precision: `exact` bytes, or `line` when only line is known."""
@enumx Precision exact line
"""Fix risk to callers; one setting picks highest tier applied automatically."""
@enumx Tier safe likely breaking manual
"""`definite`: problem exists. `possible`: compiler cannot resolve doubt either."""
@enumx Confidence definite possible
"""User-facing rule group."""
@enumx Group correctness safety performance composability readability
"""Analysis stage that computes facts rule reads, in pipeline order."""
@enumx Stage syntax package scope inference effects lifecycle external
"""File role: `package` module code precompiles; `script` code (tests, docs, scripts) runs each time it loads."""
@enumx Role package script
"""Name binding site: function `parameter`, `assignment` target, `loop` variable, `definition` name, struct `field`."""
@enumx BindingKind parameter assignment loop definition field
"""Where package lists test dependencies: `[targets].test` of Project.toml, test/Project.toml, or nowhere."""
@enumx TestDeps target project none
"""Weak value: number `literal` (tuple of them included), `constant` or call of weak values, type `name`, `variable` assigned one."""
@enumx Weak literal constant name variable
"""
Where weak value changes type: value method `returned`, value it `stored` in argument, global or returned local
container, or `intermediate` only.
"""
@enumx Exit returned stored intermediate
"""
Kind of access (`effects.md`, Effect kinds): plain `memory`, `io`, `default_rng`, `rng_argument`, `task_local` state,
`scoped_read` of `ScopedValue`, `synchronization`, `lazy_init` or `audited` internal state. Read of kind `iteration`
starts iteration (`effects.md`, Facts). Rules apply exemptions.
"""
@enumx EffectKind memory io default_rng rng_argument task_local scoped_read synchronization lazy_init audited iteration

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

"""
Registry entry: rule metadata plus pure function `run(facts::FactSet)::Vector{Finding}`. Findings need facts of
`stage`; fixes improve with facts of `fix_stage`, so run computes them when rule is on. Fix stays `manual` without them.
"""
struct RuleEntry
    name::Symbol
    group::Group.T
    footguns::Vector{Int}
    stage::Stage.T
    fix_stage::Stage.T
    run::Function
    function RuleEntry(name::Symbol, group::Group.T, footguns::Vector{Int}, stage::Stage.T, fix_stage::Stage.T, run::Function)::RuleEntry
        fix_stage >= stage || throw(ArgumentError("fix stage $fix_stage of `$name` comes before its stage $stage"))
        return new(name, group, footguns, stage, fix_stage, run)
    end
end

"""Entry whose fixes need no facts beyond its findings' `stage`."""
RuleEntry(name::Symbol, group::Group.T, footguns::Vector{Int}, stage::Stage.T, run::Function)::RuleEntry = RuleEntry(name, group, footguns, stage, stage, run)

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
        # Barriers here and in `try_match!`: package that loads later can invalidate Argus.jl internals and their callers.
        return IndexedPattern(Pattern(Base.inferencebarrier(Argus.SyntaxPatternNode)(expression)::Argus.SyntaxPatternNode))
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
other than direct ones, by name. `test_loads`: packages that load with package and its test dependencies, by name, from
Manifest of environment that loads package; `nothing` when that environment does not resolve package.
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
    test_loads::Union{Nothing, Vector{Base.PkgId}}
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
Call that never returns (`inference` stage fact): span of call statement, name span of method that holds it, name of
called function, and confidence. `definite`: inference of method on its declared signature finds no argument type that
lets call return; `possible`: it finds one. Fact holds plain data, so method store can keep it (`architecture.md`).
"""
struct FailingCall
    span::Span
    declared::Span
    callee::String
    confidence::Confidence.T
end

"""
Weak value that changes input type (`inference` stage fact). `span`: weak value, or statement that holds it when
mapping cannot narrow; `meeting`: call where it meets input; `exit_span`: statement where type changes, and `exit` how.
`value`: source text of weak value; `float`: its value when it is float number; `weak_type`: its type, or type it names;
`variable`: name variable starts with it, else empty. Types print stand-ins as models: `input` type, `found` type at
exit, `expected` type with weak value converted. `possible` when method branches on type or span cannot narrow.
`converted`: text that replaces weak value with it converted to input type (`oftype(x, 0.5)`), else `nothing`.
"""
struct Disruption
    span::Span
    meeting::Span
    exit_span::Span
    kind::Weak.T
    value::String
    float::Union{Nothing, Float64}
    weak_type::String
    variable::String
    input::String
    found::String
    expected::String
    exit::Exit.T
    confidence::Confidence.T
    converted::Union{Nothing, String}
end

"""
Type test whose narrowing `&&` or `||` chain drops (`inference` stage fact). `test`: type test term; `guard`: statement
that branches on chain value, or chain itself; `read`: first read after guard that inference types wider. `narrowed`:
type test proves; `found`: type inference gives read. `chain`: `&&` or `||`. `split`: guard text with one guard per
term, `nothing` when split is unsafe.
"""
struct NarrowingLoss
    test::Span
    guard::Span
    read::Span
    variable::String
    narrowed::String
    found::String
    chain::String
    split::Union{Nothing, String}
end

"""
Hard-coded `Array` construction that drops caller's array type (`inference` stage fact). `span`: construction call, or
statement that holds it when mapping cannot narrow; `exit_span`: statement where array returns, is stored or meets
input array, and `exit` how. `value`: source text of call, empty without node; `array`: container it builds (`Vector`,
`Matrix`, `Array`); `template`: input array argument fix builds from; `rebuilt`: text that builds same array with
`similar(template, …)`, else `nothing`. `possible` for meeting, and when method branches on type or span cannot narrow.
"""
struct HardArray
    span::Span
    exit_span::Span
    exit::Exit.T
    value::String
    array::String
    template::String
    rebuilt::Union{Nothing, String}
    confidence::Confidence.T
end

"""
Type guess for untyped argument or missing result type (`inference` stage fact, `annotation` fix). `cause`: argument
name, or signature call for result; `edit` writes annotation; `type`: guessed type text; `evidence`: observed types, at
most three, stand-ins as models. `tier`: `breaking` for argument (narrower type can reject callers) and for result of
method with untyped argument (callers outside package can pass other types); else `likely`.
"""
struct AnnotationGuess
    cause::Span
    edit::Edit
    type::String
    evidence::Vector{String}
    tier::Tier.T
end

"""
`inference` stage facts: calls that never return, one per statement, without explicit throws and calls of package
methods (their own frame reports); weak values that change input type, one per span; hard-coded arrays, one per span;
type tests whose narrowing guard drops, one per test; annotation guesses, one per cause. Typed code stays inside stage.
"""
struct InferenceFacts
    failing::Vector{FailingCall}
    disruptions::Vector{Disruption}
    hard_arrays::Vector{HardArray}
    narrowings::Vector{NarrowingLoss}
    guesses::Vector{AnnotationGuess}
end

include("Facts/effects.jl")

"""
Use of name other module neither exports nor declares `public` (`external` stage fact): module code reaches into, name
or name chain (`Precompilation.PkgPrecompileError`), its span, and whether import statement names it.
"""
struct InternalAccess
    owner::Module
    name::String
    span::Span
    imported::Bool
end

"""
Names one bare `using` brings into package module (`external` stage fact): exporter module, span of its name in
`using` statement, every used name it brings, and first use of each name in analyzed files.
"""
struct BareUsing
    exporter::Module
    statement::Span
    names::Vector{Symbol}
    uses::Vector{Tuple{Symbol, Span}}
end

"""
Explicit import statement of package module (`external` stage fact): `using X: a`, `import X: a` or `import X`. Holds
span of whole statement, names it binds, and every global use of them in its module, in source order.
"""
struct ExplicitImport
    statement::Span
    names::Vector{Symbol}
    uses::Vector{Tuple{Symbol, Span}}
end

"""
External tool output on loaded package (`external` stage facts): pairs of package method sites `Test.detect_ambiguities`
reports, earlier definition first; package method sites Aqua.jl calls type piracy; internal accesses, implicit imports
and explicit imports ExplicitImports.jl finds in analyzed files, in source order.
"""
struct ExternalFacts
    ambiguities::Vector{Tuple{MethodSite, MethodSite}}
    piracies::Vector{MethodSite}
    internal_accesses::Vector{InternalAccess}
    bare_usings::Vector{BareUsing}
    explicit_imports::Vector{ExplicitImport}
end

"""
Facts of one run: parsed files, entry files Julia loads directly (empty for directory walk, where any file may be included),
project bans from config, enclosing package project (`nothing` outside project with `name`), loaded package
(`nothing` for scripts, nameless projects, failed load, or run without package rules), inference facts, effects facts
and external tool output (each `nothing` without loaded package, or run without rules of its stage).
"""
struct FactSet
    files::Vector{SyntaxFile}
    entries::Vector{String}
    bans::Vector{Ban}
    project::Union{Nothing, ProjectFacts}
    package::Union{Nothing, PackageFacts}
    inference::Union{Nothing, InferenceFacts}
    effects::Union{Nothing, EffectsFacts}
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

"""Calls of `file` that load another file, without calls in branch no supported Julia runs."""
include_calls(file::SyntaxFile)::Vector{SyntaxNode} = filter(call -> call_head(call) in INCLUDES && !dead_branch(call), forms(file, "call"))

"""Version comparisons `settled` reads, by operator."""
const COMPARISONS = Dict{String, Function}("<" => <, "<=" => <=, ">" => >, ">=" => >=)

"""Comparison operators with operands swapped: `v"1.9" <= VERSION` reads as `VERSION >= v"1.9"`."""
const MIRRORED = Dict("<" => ">", "<=" => ">=", ">" => "<", ">=" => "<=")

"""Version `v"…"` literal `node` gives; `nothing` for other nodes."""
function version_literal(node::SyntaxNode)::Union{Nothing, VersionNumber}
    kind_name(node) == "macrocall" && length(children_of(node)) == 2 && leaf_value(children_of(node)[1]) == "@v_str" || return nothing
    pieces = children_of(children_of(node)[2])
    return length(pieces) == 1 ? tryparse(VersionNumber, something(leaf_value(pieces[1]), "")) : nothing
end

"""
Truth of version test `node` on running Julia and every later release; `nothing` when truth can change or form is unknown.
Reads `isdefined(Base, :name)`, `VERSION` compared with `v"…"`, `!`, `&&` and `||`. Platform tests stay `nothing`: other hosts differ.
"""
function settled(node::SyntaxNode)::Union{Nothing, Bool}
    pieces = children_of(node)
    if kind_name(node) in ("&&", "||")
        short = kind_name(node) == "||"
        values = map(settled, pieces)
        short in values && return short
        return all(==(!short), values) ? !short : nothing
    end
    if call_head(node) == "!"
        value = settled(pieces[2])
        return isnothing(value) ? nothing : !value
    end
    if call_head(node) == "isdefined" && length(pieces) == 3 && module_path(pieces[2]) in ("Base", "Core") && kind_name(pieces[3]) == "quote"
        name = leaf_value(children_of(pieces[3])[1])
        owner = module_path(pieces[2]) == "Base" ? Base : Core
        # Release keeps Base names, so name defined now stays; missing name may come later.
        return !isnothing(name) && isdefined(owner, Symbol(name)) ? true : nothing
    end
    operator = infix_operator(node)
    haskey(COMPARISONS, something(operator, "")) || return nothing
    left, right = pieces[1], pieces[3]
    base_name(right) == "VERSION" && ((left, right, operator) = (right, left, MIRRORED[operator]))
    version = version_literal(right)
    (base_name(left) == "VERSION" && !isnothing(version)) || return nothing
    holds = COMPARISONS[operator](VERSION, version)::Bool
    # Later releases only raise VERSION: lower bound that holds stays true, upper bound that fails stays false.
    return operator in (">", ">=") ? (holds ? true : nothing) : (holds ? nothing : false)
end

"""Whether `node` sits in branch of `if` or `elseif` that settled version test rules out."""
function dead_branch(node::SyntaxNode)::Bool
    child = node
    for owner in ancestors(node)
        if kind_name(owner) in ("if", "elseif")
            value = settled(children_of(owner)[1])
            index = findfirst(Base.Fix2(===, child), children_of(owner))
            (value === false && index == 2 || (value === true && index == 3)) && return true
        end
        child = owner
    end
    return false
end

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
    parts = String[]
    # Loop: recursive call infers `Any` inside comprehension, and `reduce` result then converts at run time.
    for piece in pieces[2:end]
        found = path_parts(file, piece)
        isnothing(found) && return nothing
        append!(parts, found)
    end
    return parts
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
    result = Base.inferencebarrier(syntax_match)(indexed.pattern, node)
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

"""
Byte where each line of `text` starts. Loop, since SparseArrays.jl `_cat` method invalidates `vcat` of number and
vector, and with it every stage that indexes lines.
"""
function line_starts(text::String)::Vector{Int}
    starts = [1]
    for (index, byte) in enumerate(codeunits(text))
        byte == UInt8('\n') && push!(starts, index + 1)
    end
    return starts
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

"""
Name node of definition `node` (function, macro, struct, module): strips `where`, result type, arguments, type parameters,
supertype. Infix definition `a ⊕ b = …` names operator; callable object method `(s::S)(x) = …` names type `S`.
"""
function definition_name(node::SyntaxNode)::SyntaxNode
    head = children_of(node)[1]
    while kind_name(head) in ("where", "::", "call", "curly", "<:") && !isempty(children_of(head))
        if kind_name(head) == "call"
            head = callee_node(head)
            kind_name(head) == "::" && (head = last(children_of(head)))
        else
            head = children_of(head)[1]
        end
    end
    return head
end

"""
Signature of function definition `node` under `where` and result type: call node, argument nodes in source order with
keyword group last, and whether result has type; `nothing` for anonymous function. Infix callee is no argument.
"""
function signature(definition::SyntaxNode)::Union{Nothing, @NamedTuple{call::SyntaxNode, arguments::Vector{SyntaxNode}, typed::Bool}}
    head, typed = children_of(definition)[1], false
    while kind_name(head) in ("where", "::") && length(children_of(head)) == 2
        typed |= kind_name(head) == "::"
        head = children_of(head)[1]
    end
    return kind_name(head) == "call" ? (call = head, arguments = call_arguments(head), typed) : nothing
end

"""Callee node of call `node`: operator of infix call `a ⊕ b`, first child otherwise."""
callee_node(node::SyntaxNode)::SyntaxNode = children_of(node)[JS.is_infix_op_call(node) ? 2 : 1]

"""Argument nodes of call `node` in source order, keyword group included: `a`, `b` of `f(a, b)` and of `a ⊕ b`."""
call_arguments(node::SyntaxNode)::Vector{SyntaxNode} = (callee = callee_node(node); [part for part in children_of(node) if part !== callee])

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
        value isa Module || return nothing
        isdefined(value, Symbol(part)) || return nothing
        value = getglobal(value, Symbol(part))
    end
    return value isa Type ? value : nothing
end

"""Span of function name at method `site`; whole line when site has no definition node."""
name_span(site::MethodSite)::Span = isnothing(site.node) ? site.span : span(site.file, definition_name(site.node))

"""
Parameters of tuple type `type` under its `where`: callee type, then argument types. Declared result type lets callers
infer `SimpleVector`; with `Any`, they dispatch at run time, and package that loads later can invalidate them.
"""
tuple_parameters(type::Type)::Core.SimpleVector = Base.unwrap_unionall(type).parameters

"""
Type of argument `position` of `method`, wrapped in signature `where`: element type for `Vararg`, bound for type variable.
`nothing` when method has no such argument.
"""
function argument_type(method::Method, position::Int)::Union{Nothing, Type}
    parameters = tuple_parameters(method.sig)
    length(parameters) > position || return nothing
    # Julia reduces `T where T <: Walk` to `Walk`, and drops type variables argument does not use.
    return Base.rewrap_unionall(Base.unwrapva(parameters[position + 1]), method.sig)
end

"""Return type inference finds for `trait(x)` over values `x` of struct `type`: `Base.HasLength` for `Base.IteratorSize`."""
function trait_type(trait::Type, type::Type)::Type
    arguments = Base.rewrap_unionall(Tuple{Base.unwrap_unionall(type)}, type)
    return Base.infer_return_type(trait, arguments)  # corset: allow inference-dependent -- rules read inference; wide trait passes
end

"""Call of `name` with argument types of tuple type `signature` after callee, as call writes it: `area(::Int64, ::T) where T<:Real`."""
function call_text(name::Symbol, signature::Type)::String
    variables, body = TypeVar[], signature
    while body isa UnionAll
        push!(variables, body.var)
        body = body.body
    end
    arguments = ("::" * (Base.isvarargtype(argument) ? "$(argument.T)..." : string(argument)) for argument in tuple_parameters(signature)[2:end])
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

"""Kinds whose value is value of a later child; first child is condition or binding block."""
const PASSING = ("if", "elseif", "?", "&&", "||", "let")

"""
Whether value of `node` goes unused: top-level statement, any statement of loop, module or `finally` body, or non-last
statement of other block. Value of branch, chain tail, `let` or `begin` body goes unused with its construct.
Last top-level statement, through `;` lines, is file value: `include` returns it. Struct body and `let` bindings
hold no statements. Condition, function result and macro argument count as used.
"""
function discarded(node::SyntaxNode)::Bool
    parent = parent_of(node)
    isnothing(parent) && return false
    kind = kind_name(parent)
    kind == "toplevel" && return children_of(parent)[end] !== node || discarded(parent)
    kind in PASSING && return children_of(parent)[1] !== node && discarded(parent)
    kind == "block" || return false
    owner = parent_of(parent)
    kind_name(owner) == "struct" && return false
    kind_name(owner) == "let" && children_of(owner)[1] === parent && return false
    children_of(parent)[end] === node || return true
    kind_name(owner) in DISCARDING && children_of(owner)[end] === parent && return true
    return kind_name(owner) in (PASSING..., "block", "toplevel") && discarded(parent)
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

"""First byte of line of `file` that holds `byte`."""
line_start(file::SyntaxFile, byte::Int)::Int = something(findprev(==(UInt8('\n')), codeunits(file.text), byte - 1), 0) + 1

"""
Bytes of lines of `file` that `span` covers, newline excluded; `nothing` when other code shares them. Trailing line
comment belongs to lines; block comment `#= =#` may hide code after it.
"""
function owned_lines(file::SyntaxFile, span::Span)::Union{Nothing, UnitRange{Int}}
    start = line_start(file, span.first_byte)
    stop = something(findnext(==(UInt8('\n')), codeunits(file.text), span.last_byte), ncodeunits(file.text) + 1) - 1
    before = SubString(file.text, start, prevind(file.text, span.first_byte))
    after = lstrip(SubString(file.text, nextind(file.text, span.last_byte), stop))
    owned = isempty(strip(before)) && (isempty(after) || (startswith(after, '#') && !startswith(after, "#=")))
    return owned ? (start:stop) : nothing
end

"""Edit deleting `lines` of `file` and newline after them; last line of file has none."""
line_deletion(file::SyntaxFile, lines::UnitRange{Int})::Edit =
    Edit(Span(file.path, first(lines), min(last(lines) + 1, ncodeunits(file.text)), Precision.exact), "")

"""Fix with no edits; shown, never applied."""
manual_fix(text::String)::Fix = Fix(text, Edit[], Tier.manual)

"""Irrational constants float literal can spell, with name of each: Base names, then IrrationalConstants.jl names."""
const IRRATIONALS = (
    (π, "π"), (ℯ, "ℯ"), (Base.MathConstants.γ, "γ"), (Base.MathConstants.φ, "φ"), (2π, "twoπ"), (π / 2, "halfπ"),
    (π / 4, "quartπ"), (1 / π, "invπ"), (sqrt(2), "sqrt2"), (1 / sqrt(2), "invsqrt2"), (sqrt(π), "sqrtπ"),
    (sqrt(2π), "sqrt2π"), (1 / sqrt(2π), "invsqrt2π"), (log(2), "logtwo"), (log(10), "logten"), (log(π), "logπ"),
)

"""Base names of `IRRATIONALS`; others come from IrrationalConstants.jl."""
const BASE_IRRATIONALS = ("π", "ℯ", "γ", "φ")

"""Name of irrational constant float `value` spells to five significant digits; `nothing` when none."""
function irrational_name(value::Float64)::Union{Nothing, String}
    for (constant, name) in IRRATIONALS
        isapprox(value, Float64(constant); rtol = 1.0e-5) && return name
    end
    return nothing
end

"""Words for weak value of `disruption` in message: literal `0.5`, constant `HALF`, conversion to `Float64`, or start value of `s`."""
function weak_words(disruption::Disruption)::String
    disruption.kind == Weak.literal && return "literal `$(disruption.value)`"
    disruption.kind == Weak.constant && return "constant `$(disruption.value)`"
    disruption.kind == Weak.name && return "conversion to `$(disruption.weak_type)`"
    return "start value of `$(disruption.variable)`"
end

"""Label at weak value of `disruption`: type weak value keeps for every input type."""
function weak_label(disruption::Disruption)::String
    disruption.kind == Weak.name && return "converts every input type to `$(disruption.weak_type)`"
    disruption.kind == Weak.variable && return "starts `$(disruption.variable)` as `$(disruption.weak_type)`"
    return "`$(disruption.weak_type)` for every input type"
end

"""
Fix of `disruption`: irrational constant for float literal that spells one (`manual`); conversion to input type
(`likely`: callers see input type), `manual` where inference stage gives no `converted` text or literal leaves
`Float32` range: `oftype(x, 1e39)` gives `Inf32`.
"""
function weak_fix(disruption::Disruption)::Fix
    irrational = isnothing(disruption.float) ? nothing : irrational_name(something(disruption.float))
    if !isnothing(irrational)
        package = irrational in BASE_IRRATIONALS ? "" : " from IrrationalConstants.jl"
        return manual_fix("use irrational `$irrational`$package; it takes input type")
    end
    value = disruption.float
    if !isnothing(value) && !iszero(value) && isfinite(value)
        narrowed = Float32(value)
        isinf(narrowed) && return manual_fix("`$(disruption.value)` overflows `Float32` input: rescale, or opt out to keep `Float64`")
        iszero(narrowed) && return manual_fix("`$(disruption.value)` rounds to zero in `Float32` input: rescale, or opt out to keep `Float64`")
    end
    converted = disruption.converted
    isnothing(converted) || return Fix("convert to input type: `$converted`", [Edit(disruption.span, converted)], Tier.likely)
    disruption.kind == Weak.name && return manual_fix("drop conversion, or keep input type with `float(x)` or `oftype(x, y)`")
    disruption.kind == Weak.variable && return manual_fix("start `$(disruption.variable)` with input type, as in `zero(T)` or `zero(eltype(xs))`")
    return manual_fix("convert `$(disruption.value)` to input type, as in `oftype(x, $(disruption.value))` or `T($(disruption.value))`")
end

"""Cause labels of `disruption`: meeting call, then statement where type changes as `exit_text` says; equal spans merge."""
function weak_causes(disruption::Disruption, exit_text::String)::Vector{Label}
    meeting = "meets `$(disruption.input)` input here"
    disruption.meeting == disruption.exit_span && return [Label(disruption.meeting, "$meeting and $exit_text")]
    return [Label(disruption.meeting, meeting), Label(disruption.exit_span, exit_text)]
end

end
