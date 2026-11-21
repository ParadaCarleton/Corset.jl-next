# Syntax helpers for statements that branch: guard chains, function result position, `if` text for fixes.
# Part of module `Facts`.

"""Whether `node` is `!` call with one argument; root has no parent, so `nothing` is none."""
negation(node::Union{Nothing, SyntaxNode})::Bool =
    !isnothing(node) && kind_name(node) == "call" && length(children_of(node)) == 2 && identifier_name(children_of(node)[1]) == "!"

"""Whether `node` leaves block: `return`, `continue`, `break`, or call of `throw`, `error` or `rethrow`."""
exits(node::SyntaxNode)::Bool = kind_name(node) in ("return", "continue", "break") ||
    (kind_name(node) == "call" && identifier_name(children_of(node)[1]) in ("throw", "error", "rethrow"))

"""Terms of chain `node` of `&&` or `||`, left to right; nested chain of same operator joins."""
function terms(node::SyntaxNode)::Vector{SyntaxNode}
    found = SyntaxNode[]
    for child in children_of(node)
        if kind_name(child) == kind_name(node)
            append!(found, terms(child))
        else
            push!(found, child)
        end
    end
    return found
end

"""Whether `node` is guard: `&&` or `||` chain whose last term exits."""
exit_guard(node::SyntaxNode)::Bool = kind_name(node) in ("&&", "||") && exits(terms(node)[end])

"""Whether `node` is later term of `&&` or `||` chain around it, so outer chain stands for it."""
function later_term(node::SyntaxNode)::Bool
    parent = parent_of(node)
    return !isnothing(parent) && kind_name(parent) in ("&&", "||") && children_of(parent)[1] !== node
end

"""Named function whose result is value of `node`; `nothing` for closure, `do` block, loop body or used value."""
function returning_function(node::SyntaxNode)::Union{Nothing, SyntaxNode}
    parent = parent_of(node)
    isnothing(parent) && return nothing
    kind = kind_name(parent)
    kind == "function" && return children_of(parent)[end] === node && kind_name(children_of(parent)[1]) != "tuple" ? parent : nothing
    passes = (kind in PASSING && children_of(parent)[1] !== node) || (kind == "block" && children_of(parent)[end] === node)
    return passes ? returning_function(parent) : nothing
end

"""Kinds whose text binds tighter than every operator: name, literal, field and index read, type application, array."""
const ATOMS = ("Identifier", ".", "ref", "curly", "string", "Bool", "Integer", "Float", "Char", "vect", "comprehension")
"""Precedence of atom, prefix call and postfix call, above every operator."""
const TIGHTEST = typemax(Int)
"""Operator whose precedence `if` condition takes: pair, assignment and anonymous function need parentheses there."""
const CONDITION = :?

"""Text of `node` without grouping parentheses around it: whole statement only. Generator keeps parentheses it needs."""
function bare(file::SyntaxFile, node::SyntaxNode)::String
    whole = span(file, node)
    text = file.text[whole.first_byte:thisind(file.text, whole.last_byte)]
    return kind_name(node) == "generator" ? "($text)" : text
end

"""
Precedence of `node` as operand, from `Base.operator_precedence`: atom, macro call `@m(x)` and prefix or postfix call
bind tightest; block, tuple and other unknown kinds bind loosest, so they keep parentheses.
"""
function precedence(file::SyntaxFile, node::SyntaxNode)::Int
    kind = kind_name(node)
    kind in ATOMS && return TIGHTEST
    kind == "macrocall" && return get(codeunits(file.text), macro_span(file, node).last_byte + 1, 0x00) == UInt8('(') ? TIGHTEST : 0
    kind in ("call", "dotcall") && !JS.is_infix_op_call(node) && return TIGHTEST
    operator = kind in ("call", "dotcall") ? bare(file, children_of(node)[2]) : kind == "comparison" ? "<" : kind
    return Base.operator_precedence(Symbol(operator))
end

"""Text of `node` as operand of `operator`; parentheses only when `node` binds looser than `operator`."""
operand(file::SyntaxFile, node::SyntaxNode, operator::Symbol)::String =
    precedence(file, node) >= Base.operator_precedence(operator) ? bare(file, node) : "(" * bare(file, node) * ")"

"""Statement lines of branch `node`, joined at `indent`: parenthesized block gives one line per statement."""
body_text(file::SyntaxFile, node::SyntaxNode, indent::String)::String =
    kind_name(node) == "block" ? join((bare(file, child) for child in children_of(node)), "\n" * indent) : bare(file, node)

"""Text of `!` applied to `node`, as operand of `operator`: `!` call drops its `!`; atom takes `!`; rest gets parentheses."""
function negated(file::SyntaxFile, node::SyntaxNode, operator::Symbol)::String
    negation(node) && return operand(file, children_of(node)[2], operator)
    text = bare(file, node)
    # `!` and leading `=` lex as one operator: `!==(a, b)` reads as `!==`.
    return precedence(file, node) == TIGHTEST && !startswith(text, '=') ? "!" * text : "!($text)"
end

"""Condition text that holds when every term of `nodes` is false: `!a && !b`; `&&` term turns into `||` of negated terms."""
function none_text(file::SyntaxFile, nodes::Vector{SyntaxNode})::String
    single = length(nodes) == 1
    parts = map(nodes) do node
        kind_name(node) == "&&" || return negated(file, node, single ? CONDITION : :&&)
        text = join((negated(file, term, :||) for term in terms(node)), " || ")
        return single ? text : "($text)"
    end
    return join(parts, " && ")
end

"""Condition and body text of one `if` branch; `nothing` condition is `else`."""
const Branch = Pair{Union{Nothing, String}, String}

"""`if` statement text whose first line starts after `indent`; body lines indent four spaces deeper."""
function if_text(branches::Vector{Branch}, indent::String)::String
    lines = String[]
    for (index, (condition, body)) in enumerate(branches)
        head = isnothing(condition) ? "else" : (index == 1 ? "if " : "elseif ") * condition
        push!(lines, (index == 1 ? "" : indent) * head, indent * "    " * body)
    end
    return join(push!(lines, indent * "end"), "\n")
end

"""Indent of statement `node` when it owns its lines and holds no comment; `nothing` otherwise, so rewrite stays manual."""
function statement_indent(file::SyntaxFile, node::SyntaxNode)::Union{Nothing, String}
    whole = span(file, node)
    isnothing(owned_lines(file, whole)) && return nothing
    isempty(comments_in(file, whole.first_byte:whole.last_byte)) || return nothing
    return file.text[line_start(file, whole.first_byte):prevind(file.text, whole.first_byte)]
end
