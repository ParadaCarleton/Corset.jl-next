"""
`inference` stage scan for type tests whose narrowing `&&` or `||` value drops (`lost-narrowing`).

Lowering stores value of `a && b` in variable before guard `|| return` branches on it. Inference narrows variable on
branch of type test only, so code after guard reads untested type. Scan follows control flow as inference does, and
also carries what each stored condition proves. Read where scan proves narrower type than inference gives is loss.
"""
module Narrowing

using ..Facts: SyntaxFile, SyntaxNode, kind_name, children_of, parent_of, identifier_name, source, span, discarded, owned_lines, comments_in, line_start
using ..Widening: resolved, statement_call

const CC = Core.Compiler

"""Control flow graph of typed code, and variable types inference gives at start of each block; `nothing` for unreached block."""
struct Flow
    graph::CC.CFG
    tables::Vector{Union{Nothing, Vector{CC.VarState}}}
end

"""
Read of variable `slot` at statement `read` that inference types `found`, though type test at statement `test` proves
`narrowed` there.
"""
struct Loss
    test::Int
    read::Int
    slot::Int
    narrowed::Type
    found::Type
end

"""Variable type that control flow proves, and statement of type test that proves it, by slot."""
const Proven = Dict{Int, Tuple{Type, Int}}

"""What one value of condition proves; `nothing` when condition never takes that value there."""
const Outcome = Union{Nothing, Proven}

"""Scan state: what control flow proves, and what each variable holding condition proves when true and when false."""
const State = @NamedTuple{proven::Proven, stored::Dict{Int, Tuple{Outcome, Outcome}}}

"""Facts both outcomes prove: type joins as union, earlier test stays. Outcome that never happens adds nothing."""
function meet(left::Outcome, right::Outcome)::Outcome
    isnothing(left) && return right
    isnothing(right) && return left
    met = Proven()
    for (slot, (type, test)) in left
        haskey(right, slot) && (met[slot] = (Union{type, right[slot][1]}, min(test, right[slot][2])))
    end
    return met
end

"""State where two paths join; variable that holds condition on one path only proves nothing."""
function meet(left::State, right::State)::State
    stored = Dict{Int, Tuple{Outcome, Outcome}}()
    for (slot, (yes, no)) in left.stored
        haskey(right.stored, slot) && (stored[slot] = (meet(yes, right.stored[slot][1]), meet(no, right.stored[slot][2])))
    end
    return (proven = something(meet(left.proven, right.proven)), stored = stored)
end

"""`proven` with `slot` narrowed to `type` by test at statement `test`."""
narrowed(proven::Proven, slot::Int, type::Type, test::Int)::Proven = (updated = copy(proven); updated[slot] = (type, test); updated)

"""`proven` and facts of `outcome` together; `nothing` when outcome never happens."""
combined(proven::Proven, outcome::Outcome)::Outcome = isnothing(outcome) ? nothing : merge(proven, outcome)

"""`outcome` without facts about `slot`, which assignment replaces."""
forget(outcome::Outcome, slot::Int)::Outcome = isnothing(outcome) ? nothing : delete!(copy(outcome), slot)

"""Type of variable `slot` before statement: type assignment earlier in block gives, else type at start of block."""
slot_type(table::Vector{CC.VarState}, assigned::Dict{Int, <:Type}, slot::Int)::Type =
    get(() -> CC.widenconst(table[slot].typ), assigned, slot)

"""
Variable, narrowed type and test result that narrows, for type test `call`: `x isa T`, `x !== nothing`,
`x === nothing`, `isnothing(x)`. `nothing` for other call, or test that narrows nothing. Narrowed type `Union{}`
means test never gives that result here: lowering reads `x === nothing` again on its own true branch.
"""
function type_test(code::Core.CodeInfo, call::Expr, parameters::Vector{CC.VarState}, table::Vector{CC.VarState}, assigned::Dict{Int, <:Type})::Union{Nothing, Tuple{Int, Type, Bool}}
    callee = CC.argextype(call.args[1], code, parameters)
    callee isa Core.Const || return nothing
    arguments = Any[resolved(code, argument) for argument in call.args[2:end]]
    test, slots = callee.val, findall(argument -> argument isa Core.SlotNumber, arguments)
    length(slots) == 1 || return nothing
    slot = arguments[only(slots)].id
    current = slot_type(table, assigned, slot)
    if test === isa && length(arguments) == 2 && only(slots) == 1
        tested = CC.argextype(call.args[3], code, parameters)
        tested isa Core.Const || return nothing
        tested.val isa Type || return nothing
        type, holds = typeintersect(current, tested.val), true
    elseif (test === (===) || test === (!==)) && length(arguments) == 2
        CC.argextype(call.args[1 + (3 - only(slots))], code, parameters) == Core.Const(nothing) || return nothing
        type, holds = Base.nonnothingtype(current), test === (!==)
    elseif test === isnothing && length(arguments) == 1
        type, holds = Base.nonnothingtype(current), false
    else
        return nothing
    end
    return type == current ? nothing : (slot, type, holds)
end

"""
What `condition` proves when true and when false, as of statement `index`: type test, its negation, or variable that
holds condition. Test statement is `condition` itself when it is call expression.
"""
function outcomes(code::Core.CodeInfo, condition::Any, index::Int, state::State, parameters::Vector{CC.VarState}, table::Vector{CC.VarState}, assigned::Dict{Int, <:Type})::Tuple{Outcome, Outcome}
    unchanged = (state.proven, state.proven)
    if condition isa Core.SSAValue
        index, condition = condition.id, code.code[condition.id]
    end
    condition isa Core.SlotNumber && return map(outcome -> combined(state.proven, outcome), get(state.stored, condition.id, unchanged))
    condition === true && return (state.proven, nothing)
    condition === false && return (nothing, state.proven)
    call = statement_call(condition)
    isnothing(call) && return unchanged
    if CC.argextype(call.args[1], code, parameters) == Core.Const(!) && length(call.args) == 2
        yes, no = outcomes(code, call.args[2], index, state, parameters, table, assigned)
        return no, yes
    end
    tested = type_test(code, call, parameters, table, assigned)
    isnothing(tested) && return unchanged
    slot, type, holds = tested
    proven = type === Union{} ? nothing : narrowed(state.proven, slot, type, index)
    return holds ? (proven, state.proven) : (state.proven, proven)
end

"""Slots `statement` reads as values: call arguments, assigned value, condition, returned value."""
function read_slots!(found::Vector{Int}, statement::Any)::Vector{Int}
    if statement isa Core.SlotNumber
        push!(found, statement.id)
    elseif statement isa Expr && statement.head in (:call, :invoke, :new, :foreigncall, :(=))
        foreach(argument -> read_slots!(found, argument), statement.head === :(=) ? statement.args[2:2] : statement.args)
    elseif statement isa Core.GotoIfNot
        read_slots!(found, statement.cond)
    elseif statement isa Core.ReturnNode && isdefined(statement, :val)
        read_slots!(found, statement.val)
    end
    return found
end

"""
Run of block `block` from `state`: state at start of each successor. Pushes reads that lose narrowing to `losses`.
Call that never returns ends block.
"""
function transfer!(losses::Vector{Loss}, code::Core.CodeInfo, flow::Flow, parameters::Vector{CC.VarState}, block::Int, state::State)::Vector{Pair{Int, State}}
    table = something(flow.tables[block])
    proven, stored, assigned = copy(state.proven), copy(state.stored), Dict{Int, Type}()
    for index in flow.graph.blocks[block].stmts
        statement = code.code[index]
        for slot in read_slots!(Int[], statement)
            haskey(proven, slot) || continue
            type, test = proven[slot]
            found = slot_type(table, assigned, slot)
            found <: type || push!(losses, Loss(test, index, slot, type, found))
        end
        current = (proven = proven, stored = stored)
        if statement isa Core.GotoIfNot
            yes, no = outcomes(code, statement.cond, index, current, parameters, table, assigned)
            target = CC.block_for_inst(flow.graph, statement.dest)
            return Pair{Int, State}[next => (proven = outcome, stored = stored) for (next, outcome) in ((block + 1, yes), (target, no)) if !isnothing(outcome)]
        elseif statement isa Core.GotoNode
            return [CC.block_for_inst(flow.graph, statement.label) => current]
        elseif statement isa Core.ReturnNode
            return Pair{Int, State}[]
        elseif statement isa Core.EnterNode && statement.catch_dest != 0
            # Handler runs after any statement of `try` body, so it proves nothing.
            return [block + 1 => current, CC.block_for_inst(flow.graph, statement.catch_dest) => (proven = Proven(), stored = Dict{Int, Tuple{Outcome, Outcome}}())]
        elseif statement isa Expr && statement.head === :(=) && statement.args[1] isa Core.SlotNumber
            slot = statement.args[1].id
            yes, no = outcomes(code, statement.args[2], index, current, parameters, table, assigned)
            delete!(proven, slot)
            for (other, (was_yes, was_no)) in stored
                stored[other] = (forget(was_yes, slot), forget(was_no, slot))
            end
            CC.widenconst(code.ssavaluetypes[index]) <: Bool ? (stored[slot] = (forget(yes, slot), forget(no, slot))) : delete!(stored, slot)
            assigned[slot] = CC.widenconst(code.ssavaluetypes[index])
        end
        statement isa Expr && code.ssavaluetypes[index] === Union{} && return Pair{Int, State}[]
    end
    return block < length(flow.graph.blocks) ? [block + 1 => (proven = proven, stored = stored)] : Pair{Int, State}[]
end

"""
Reads of typed `code` that lose narrowing type test proves, first read per test. Scan runs to fixed point, then once
more to collect reads.
"""
function losses(code::Core.CodeInfo, flow::Flow, parameters::Vector{CC.VarState})::Vector{Loss}
    blocks = flow.graph.blocks
    (length(flow.tables) == length(blocks) && last(blocks[end].stmts) == length(code.code)) || error("control flow graph does not cover typed code")
    states = Union{Nothing, State}[nothing for _ in flow.graph.blocks]
    states[1] = (proven = Proven(), stored = Dict{Int, Tuple{Outcome, Outcome}}())
    pending, ignored = [1], Loss[]
    while !isempty(pending)
        block = popfirst!(pending)
        isnothing(flow.tables[block]) && continue
        for (next, state) in transfer!(ignored, code, flow, parameters, block, something(states[block]))
            met = isnothing(states[next]) ? state : meet(something(states[next]), state)
            met == states[next] && continue
            states[next] = met
            next in pending || push!(pending, next)
        end
    end
    found = Loss[]
    for (block, state) in enumerate(states)
        isnothing(state) || isnothing(flow.tables[block]) || transfer!(found, code, flow, parameters, block, state)
    end
    return unique!(loss -> loss.test, sort!(found; by = loss -> loss.read))
end

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
        kind_name(child) == kind_name(node) ? append!(found, terms(child)) : push!(found, child)
    end
    return found
end

"""
Guard around type test: `term` holds test and its negations, `chain` of `&&` or `||` holds term, `statement` branches on
chain value (chain itself when no guard form matches), and `split` is guard text with one guard per term, or `nothing`.
"""
struct Guard
    term::SyntaxNode
    chain::SyntaxNode
    statement::SyntaxNode
    split::Union{Nothing, String}
end

"""Guard of one chain `term` with `exit` text: `x isa T || exit`; negation drops, `!isnothing(x)` gives `isnothing(x) && exit`."""
guard_text(file::SyntaxFile, term::SyntaxNode, exit::String)::String =
    negation(term) ? "$(source(file, children_of(term)[2])) && $exit" : "$(source(file, term)) || $exit"

"""
Guard around type test `node` (`Guard`); `nothing` when node is outside chain. Guard forms: `(a && b) || exit` and
`if !(a && b) exit end`; lowering branches on `||` chain directly, so it keeps narrowing. Split needs guard as own
statement whose value goes unused, with `exit` that leaves block and no comment inside. Term binds tighter than `||`
unless grouping parentheses wrap it, and `source` keeps those.
"""
function guard(file::SyntaxFile, node::SyntaxNode)::Union{Nothing, Guard}
    term = node
    while negation(parent_of(term))
        term = parent_of(term)
    end
    chain = parent_of(term)
    (isnothing(chain) || !(kind_name(chain) in ("&&", "||"))) && return nothing
    while kind_name(parent_of(chain)) == kind_name(chain)
        chain = parent_of(chain)
    end
    outer = parent_of(chain)
    if kind_name(chain) == "&&" && kind_name(outer) == "||" && children_of(outer)[1] === chain
        statement, exit = outer, children_of(outer)[2]
    elseif kind_name(chain) == "&&" && negation(outer) && kind_name(parent_of(outer)) == "if" && length(children_of(parent_of(outer))) == 2 &&
            length(children_of(children_of(parent_of(outer))[2])) == 1
        statement, exit = parent_of(outer), only(children_of(children_of(parent_of(outer))[2]))
    else
        return Guard(term, chain, chain, nothing)
    end
    whole = span(file, statement)
    splits = discarded(statement) && exits(exit) && !haskey(file.groups, statement) && !isnothing(owned_lines(file, whole)) &&
        isempty(comments_in(file, whole.first_byte:whole.last_byte))
    splits || return Guard(term, chain, statement, nothing)
    indent = file.text[line_start(file, whole.first_byte):prevind(file.text, whole.first_byte)]
    exit_text = source(file, exit)
    lines = [guard_text(file, part, exit_text) for part in terms(chain)]
    return Guard(term, chain, statement, join(lines, "\n" * indent))
end

end
