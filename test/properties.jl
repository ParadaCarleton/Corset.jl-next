# Fix properties with Supposition.jl: programs join UI case statements with spliced expressions, then fix at random tier.
# Set CORSET_PROPERTY_EXAMPLES to run more examples per property.

using Corset: Corset
using Corset.Facts: FactSet, Finding, Tier, Role, call_head, children_of, kind_name, parent_of
using Corset.Syntax: JS
using Supposition: Supposition, @check, @composed, Data, assume!
using Test: @test, @testset

const PROGRAM = "program.jl"
const EXAMPLES = parse(Int, get(ENV, "CORSET_PROPERTY_EXAMPLES", "1000"))
"""Shrunk failures replay first on next local run; git ignores directory."""
const EXAMPLE_DB = Supposition.DirectoryDB(joinpath(@__DIR__, "SuppositionDB"))
"""Module that statements lower in; lowering expands macros and runs nothing."""
const SANDBOX = Module(:Sandbox)

"""Findings of every rule on `text` as one package file, so rules for package code run too."""
findings_of(text::String)::Vector{Finding} = Corset.Engine.run_rules(FactSet([Corset.Syntax.parse_file(PROGRAM, text, Role.package)], [PROGRAM], Corset.Facts.Ban[]))

"""Edits one fix run applies to `findings` at `tier`."""
edits_of(findings::Vector{Finding}, tier::Tier.T)::Vector{Corset.Facts.Edit} = Corset.Fixes.applicable_edits(findings, PROGRAM, tier)

"""`text` after one fix run at `tier`."""
fixed_once(text::String, tier::Tier.T)::String = Corset.Fixes.apply_edits(text, edits_of(findings_of(text), tier))

"""Whether `text` parses without errors."""
function parses(text::String)::Bool
    try
        JS.parseall(JS.SyntaxNode, text)
        return true
    catch error
        error isa JS.ParseError || rethrow()
        return false
    end
end

"""
Statements of `expression` that fail to lower, module bodies included. Failed macro expansion counts;
statement with macro defined outside program counts as lowered, since lowering cannot judge it.
"""
function lowering_errors(expression::Any)::Int
    expression isa Expr || return 0
    expression.head === :toplevel && return sum(lowering_errors, expression.args; init = 0)
    expression.head === :module && return lowering_errors(Expr(:toplevel, expression.args[end].args...))
    lowered = try
        Meta.lower(SANDBOX, expression)
    catch error
        error isa LoadError || rethrow()
        return error.error isa UndefVarError ? 0 : 1
    end
    return lowered isa Expr && lowered.head in (:error, :incomplete) ? 1 : 0
end

"""Whether Julia accepts `text`: it parses, and every statement lowers."""
accepted(text::String)::Bool = parses(text) && lowering_errors(Meta.parseall(text)) == 0

"""Whether assignment target `target` names method, as in `f(x) = …` or `f(x)::T where {T} = …`."""
names_method(target::Any)::Bool = target isa Expr && (target.head === :call || target.head in (:where, :(::)) && names_method(target.args[1]))

"""
Index of body in `arguments` of `head` whose statements all drop their value; `0` for other heads.
Module and loop bodies come last: Julia 1.14 adds syntax version before module name. `try` holds `finally` fourth.
"""
dropping_body(head::Symbol, arguments::Vector{Any})::Int = head in (:module, :for, :while) ? lastindex(arguments) : head === :try ? 4 : 0

"""Whether `argument` is string literal; interpolated string may run code, so it stays."""
is_string(argument::Any)::Bool = argument isa String

"""
`expression` without line numbers, docstrings, dropped string statements, and `return` on last statement of method body.
Julia drops value of string statement unless it is last of block; module, loop and `finally` bodies drop every value.
"""
function normalized(expression::Any)::Any
    expression isa Expr || return expression
    expression.head === :macrocall && expression.args[1] == GlobalRef(Core, Symbol("@doc")) && return normalized(expression.args[end])
    arguments = Any[normalized(argument) for argument in expression.args if !(argument isa LineNumberNode)]
    if expression.head in (:block, :toplevel)
        last_index = length(arguments)
        arguments = Any[argument for (index, argument) in enumerate(arguments) if index == last_index || !is_string(argument)]
    end
    body = dropping_body(expression.head, arguments)
    checkbounds(Bool, arguments, body) && Meta.isexpr(arguments[body], :block) && (arguments[body] = Expr(:block, filter(!is_string, arguments[body].args)...))
    if expression.head === :function || expression.head === :(=) && names_method(arguments[1])
        body = arguments[end]
        tail = body isa Expr && body.head === :block && !isempty(body.args) ? body.args[end] : nothing
        tail isa Expr && tail.head === :return && (body.args[end] = only(tail.args))
    end
    return Expr(expression.head, arguments...)
end

"""`lines` without common leading spaces; blank lines become empty."""
function dedent(lines::Vector{<:AbstractString})::String
    margin = minimum(line -> length(line) - length(lstrip(line, ' ')), filter(line -> !isempty(strip(line)), lines))
    return join((isempty(strip(line)) ? "" : line[(margin + 1):end] for line in lines), '\n')
end

"""Nodes of subtree at `node`, parents first."""
subtree(node::JS.SyntaxNode)::Vector{JS.SyntaxNode} = [node; reduce(vcat, map(subtree, children_of(node)); init = JS.SyntaxNode[])]

"""Bytes of `node` in `text`."""
node_text(text::String, node::JS.SyntaxNode)::String = String(codeunits(text)[JS.first_byte(node):JS.last_byte(node)])

"""`text` with disjoint byte ranges replaced."""
function splice_bytes(text::String, replacements::Dict{UnitRange{Int}, String})::String
    bytes, pieces, cursor = codeunits(text), String[], 1
    for (range, replacement) in sort!(collect(replacements); by = pair -> first(pair.first))
        push!(pieces, String(bytes[cursor:(first(range) - 1)]), replacement)
        cursor = last(range) + 1
    end
    return join(push!(pieces, String(bytes[cursor:end])))
end

"""Children of `parent` that stand for values: arguments, operands, elements, conditions, assigned and returned values."""
function value_children(parent::JS.SyntaxNode)::Vector{JS.SyntaxNode}
    children, kind = children_of(parent), kind_name(parent)
    # `ccall` function, return type and argument types are constants; only trailing arguments are values.
    call_head(parent) == "ccall" && return children[5:end]
    kind in ("call", "dotcall") && return [child for child in children if child !== children[JS.is_infix_op_call(parent) ? 2 : 1]]
    kind in ("vect", "row", "hcat", "vcat", "tuple", "ref", "return", "&&", "||", "?") && return children
    kind == "=" && return children[2:2]
    kind in ("if", "elseif", "while") && return children[1:1]
    return JS.SyntaxNode[]
end

"""Kinds whose subtree holds names, types, or code that runs elsewhere; splices stay out."""
const OPAQUE = ("macrocall", "quote", "::", "curly", "where", "->", "do", "struct", "macro", "iteration", ".")

"""Whether `node` stands for value in code that runs here, outside definition signatures and assignment targets."""
function value_position(node::JS.SyntaxNode)::Bool
    child, parent = node, parent_of(node)
    any(value -> value === node, value_children(parent)) || return false
    while !isnothing(parent)
        kind = kind_name(parent)
        kind in OPAQUE && return false
        kind in ("function", "=") && children_of(parent)[1] === child && return false
        child, parent = parent, parent_of(parent)
    end
    return true
end

"""Byte ranges of identifiers in value positions of `text`; splices go only there, so spliced code stays code people write."""
holes(text::String)::Vector{UnitRange{Int}} =
    [JS.first_byte(node):JS.last_byte(node) for node in subtree(JS.parseall(JS.SyntaxNode, text)) if kind_name(node) == "Identifier" && value_position(node)]

"""Source lines of statement `node` in `text`, with comment lines directly above it."""
function statement_text(text::String, node::JS.SyntaxNode)::String
    lines = split(text, '\n')
    line_of(byte::Int) = count(==(UInt8('\n')), view(codeunits(text), 1:(byte - 1))) + 1
    top, bottom = line_of(JS.first_byte(node)), line_of(JS.last_byte(node))
    while top > 1 && occursin(r"^\s*#(?!=)", lines[top - 1]) && lines[top - 1] != "# runic: off"
        top -= 1
    end
    return dedent(lines[top:bottom])
end

"""Text and tree of every UI case."""
const CASES = [
    (text, JS.parseall(JS.SyntaxNode, text; ignore_errors = true))
        for text in read.([joinpath(root, name) for (root, _, names) in walkdir(joinpath(@__DIR__, "ui")) for name in names if endswith(name, ".jl")], String)
]

"""`texts` that parse alone, shortest first so shrinking moves to short texts; texts that differ only in digits count once."""
distinct(texts::Vector{String})::Vector{String} = unique(text -> replace(text, r"\d+" => "0"), sort!(filter(parses, unique(texts)); by = text -> (sizeof(text), text)))

"""UI case statements: children of top-level and block nodes."""
const STATEMENTS = distinct([statement_text(text, child) for (text, tree) in CASES for node in subtree(tree) if kind_name(node) in ("toplevel", "block") for child in children_of(node)])
"""Definition kinds; definition spliced into expression gives code nobody writes."""
const DEFINITIONS = ("function", "doc", "macro", "struct", "module", "abstract", "primitive", "const", "global", "local", "using", "import", "export")
"""Kind of first statement of `text`; `nothing` for text without code, such as empty `let` binding list."""
function root_kind(text::String)::Union{Nothing, String}
    statements = children_of(JS.parseall(JS.SyntaxNode, text))
    return isempty(statements) ? nothing : kind_name(first(statements))
end
"""One-line inner nodes of UI cases, definitions and code-free text excluded; splices put them in place of identifiers."""
const EXPRESSIONS = filter(
    text -> root_kind(text) ∉ (nothing, DEFINITIONS...),
    distinct(filter(text -> sizeof(text) <= 40 && !occursin('\n', text), [node_text(text, node) for (text, tree) in CASES for node in subtree(tree) if !JS.is_leaf(node)])),
)
const HOLES = Dict(statement => holes(statement) for statement in STATEMENTS)
const WRAPPERS = [("function wrapped()", "end"), ("begin", "end"), ("let", "end"), ("module Wrapped", "end"), ("if flag", "end")]

"""Whether one fix run changes `text`."""
fixable(text::String)::Bool = !isempty(edits_of(findings_of(text), Tier.breaking))

"""Draw from fixable `texts` half of time, else from all `texts`."""
biased(texts::Vector{String})::Data.Possibility{String} = Data.OneOf(Data.SampledFrom(filter(fixable, texts)), Data.SampledFrom(texts))

"""`text` with four spaces before every nonblank line."""
indent(text::String)::String = join((isempty(line) ? line : "    " * line for line in split(text, '\n')), '\n')

# `@composed` evaluates argument defaults on every draw: build generators once here.
# Small counts use `Data.Integers`; `Data.Vectors` with small `max_size` draws empty vectors early in run.
const STATEMENT, SPLICE, WRAPPER = biased(STATEMENTS), Data.Pairs(Data.Integers(1, 64), biased(EXPRESSIONS)), Data.SampledFrom(WRAPPERS)
const COUNT = Data.Integers(0, 2)

"""Statement with up to two identifiers replaced by parenthesized expressions, so fixes nest."""
const SPLICED = @composed function spliced(statement = STATEMENT, splices = COUNT, first_splice = SPLICE, second_splice = SPLICE)
    targets = HOLES[statement]
    isempty(targets) && return statement
    return splice_bytes(statement, Dict(targets[mod1(index, length(targets))] => "($expression)" for (index, expression) in [first_splice, second_splice][1:splices]))
end

const PARTS, SEPARATOR = Data.Vectors(SPLICED; min_size = 1, max_size = 16), Data.SampledFrom(["\n", "\n\n"])

"""Spliced statements, joined, inside up to two block wrappers."""
const PROGRAMS = @composed function program(parts = PARTS, separator = SEPARATOR, depth = COUNT, outer = WRAPPER, inner = WRAPPER)
    body = join(parts, separator)
    for (head, tail) in [inner, outer][1:depth]
        body = join([head, indent(body), tail], '\n')
    end
    return body * "\n"
end
const TIERS = Data.SampledFrom(collect(instances(Tier.T)))
"""Rules that compare code as text; fix that rewrites code into text of other code reveals real match, such as two equal lock targets."""
const TEXT_MATCH_RULES = [Symbol("duplicate-statement"), Symbol("unguarded-release"), :unreachable]
"""Rules whose `safe` fix spells out what parser already reads: proven equivalent."""
const EQUIVALENT = [:docstring, :juxtaposition, Symbol("mixed-return"), Symbol("unused-literal")]
"""Rules whose `safe` fix changes meaning to fix definite bug inside method."""
const BUG_FIXES = [Symbol("where-binding"), Symbol("world-age")]

"""Rules with `safe` fix in UI positive cases."""
function safe_rules()::Vector{Symbol}
    positives = [read(joinpath(@__DIR__, "ui", rule, "positive.jl"), String) for rule in readdir(joinpath(@__DIR__, "ui"))]
    safe = [finding.rule for text in positives for finding in findings_of(text) if !isnothing(finding.fix) && finding.fix.tier == Tier.safe && !isempty(finding.fix.edits)]
    return sort!(unique(safe))
end

@testset "fix properties" begin
    @test count(fixable, STATEMENTS) >= 6 && count(fixable, EXPRESSIONS) >= 2
    @test safe_rules() == sort!([EQUIVALENT; BUG_FIXES])
    same(left::String, right::String)::Bool = normalized(Meta.parseall(left)) == normalized(Meta.parseall(right))
    @test same("module M\n\"a\"\nend\n", "module M\nend\n") && same("for i in 1:2\n\"a\"\nend\n", "for i in 1:2\nend\n")
    @test same("while f()\n\"a\"\nend\n", "while f()\nend\n") && same("try\nf()\nfinally\n\"a\"\nend\n", "try\nf()\nfinally\nend\n")
    @test !same("f() = \"a\"\n", "f() = nothing\n") && !same("\"a\"\n", "")
    @test !same("function f(xs)\n\"\$(push!(xs, 1))\"\nnothing\nend\n", "function f(xs)\nnothing\nend\n")
    wrapped = "module Wrapped\n    \"Shape types.\"\nend\n"
    @test Corset.Fixes.apply_edits(wrapped, edits_of(findings_of(wrapped), Tier.safe)) == "module Wrapped\n    # Shape types.\nend\n"
    # `mixed-return` fix wraps `pinned.sticky = false` in `return`; `pinned-task` opt-out still holds.
    returned = "function wrapped()\n    return missing\n    pinned = Task(work); pinned.sticky = false\nend\n"
    @test occursin("return pinned.sticky", fixed_once(returned, Tier.safe)) && !any(finding -> finding.rule == Symbol("pinned-task"), findings_of(fixed_once(returned, Tier.safe)))

    # Comment text becomes docstring with same value; quotes, backslashes and dollar signs included.
    @check max_examples = EXAMPLES db = EXAMPLE_DB function docstring_keeps_text(line = Data.Text(Data.SampledFrom(collect("a \"\\\$#()")); max_len = 12))
        return Meta.parse("\"\"\"" * Corset.Rules.Docstring.escaped(line) * "\"\"\"") == line
    end

    @check max_examples = EXAMPLES db = EXAMPLE_DB function fix_keeps_code_valid(text = PROGRAMS, tier = TIERS)
        fixed = fixed_once(text, tier)
        return (!parses(text) || parses(fixed)) && lowering_errors(Meta.parseall(fixed)) <= lowering_errors(Meta.parseall(text))
    end

    # On code Julia accepts, fix of rule removes its finding and adds no finding of any rule.
    @check max_examples = EXAMPLES db = EXAMPLE_DB function fix_removes_findings(text = PROGRAMS, tier = TIERS)
        assume!(accepted(text))
        before = findings_of(text)
        edits = edits_of(before, tier)
        after = findings_of(Corset.Fixes.apply_edits(text, edits))
        applied = filter(finding -> !isnothing(finding.fix) && !isempty(finding.fix.edits) && all(in(edits), finding.fix.edits), before)
        tally(findings::Vector{Finding}, rule::Symbol)::Int = count(finding -> finding.rule == rule, findings)
        return all(tally(after, rule) <= tally(before, rule) - tally(applied, rule) for rule in setdiff([entry.name for entry in Corset.Rules.REGISTRY], TEXT_MATCH_RULES))
    end

    # Equivalent fixes keep meaning; differential run of all `safe` fixes waits for execution harness.
    @check max_examples = EXAMPLES db = EXAMPLE_DB function fix_keeps_meaning(text = PROGRAMS)
        assume!(accepted(text))
        fixed = Corset.Fixes.apply_edits(text, edits_of(filter(finding -> finding.rule in EQUIVALENT, findings_of(text)), Tier.safe))
        return normalized(Meta.parseall(fixed)) == normalized(Meta.parseall(text))
    end

    # Each run removes a finding, so fix runs stop within one run per finding.
    @check max_examples = EXAMPLES db = EXAMPLE_DB function fix_converges(text = PROGRAMS, tier = TIERS)
        for _ in 0:length(findings_of(text))
            fixed = fixed_once(text, tier)
            fixed == text && return true
            text = fixed
        end
        return false
    end
end
