"""
IR of inference `frame` before inlining, source statement index of each IR statement (0: compiler inserted it), and
whether value of each source statement has use (`effects.md`, IR). Passes run on copies, so frame stays as `inference`
stage left it. Line of each statement carries its index through passes. Compaction keeps statements `kept` marks,
though compiler effects let it delete them.
"""
function frame_ir(frame::CC.InferenceState, interpreter::CC.NativeInterpreter, kept::AbstractVector{Bool})::Tuple{CC.IRCode, Vector{Int}, Vector{Bool}}
    source = copy(frame.src)
    count = length(source.code)
    for index in findall(kept)
        source.ssaflags[index] &= ~CC.IR_FLAG_EFFECT_FREE
    end
    stream = CC.DebugInfoStream(Int32[part for index in 1:count for part in (index, 0, 0)])
    stream.def = frame.linfo
    source.debuginfo = Core.DebugInfo(stream, count)
    # Conversion edits control flow and statement info in place and empties unreachable set; `slot2reg` truncates slot types.
    optimization = CC.OptimizationState(
        frame.linfo, source, nothing, copy(frame.stmt_info), frame.mod, frame.sptypes, copy(frame.slottypes),
        CC.InliningState(frame, interpreter), deepcopy(frame.cfg), copy(frame.unreachable), frame.bb_vartables, frame.insert_coverage,
    )
    renamed = CC.run_passes_ipo_safe(source, optimization, "CC: SLOT2REG")
    # Compaction turns each use of constant result into literal (`Compiler` `ssair/ir.jl`), so uses come first.
    used = source_used(renamed, count)
    ir = CC.compact!(renamed)
    return ir, [statement_line(ir, index) for index in 1:length(ir.stmts)], used
end

"""Source statement index of statement `index` of `ir` (`frame_ir`)."""
statement_line(ir::CC.IRCode, index::Integer)::Int = Int(ir.stmts[index][:line][1])

"""Whether value of each of `count` source statements has use in `ir` before compaction: in statement or in new node."""
function source_used(ir::CC.IRCode, count::Integer)::Vector{Bool}
    used = fill(false, count)
    for statement in Iterators.flatten((ir.stmts.stmt, ir.new_nodes.stmts.stmt)), reference in CC.userefs(statement)
        value = reference[]
        value isa Core.SSAValue || continue
        value.id <= length(ir.stmts) || continue
        line = statement_line(ir, value.id)
        iszero(line) || (used[line] = true)
    end
    return used
end

"""Types whose values point to no object Corset tracks: type objects, modules, symbols and strings."""
const PLAIN = Union{Type, Core.TypeName, Module, Symbol, String, Core.MethodInstance, Method}

"""
Whether value of `type` can point to object effects can reach: mutable, abstract, `Ptr`, or holds such field. `cache`
keeps answers; recursive struct counts as pointing.
"""
function referent!(cache::IdDict{Any, Bool}, @nospecialize(type::Any))::Bool
    haskey(cache, type) && return cache[type]
    cache[type] = true
    answer = if type isa Union
        referent!(cache, type.a) || referent!(cache, type.b)
    elseif type isa UnionAll || !(type isa DataType) || !isconcretetype(type)
        !(type <: PLAIN)
    elseif type <: PLAIN
        false
    elseif type <: Ptr || ismutabletype(type)
        true
    else
        any(index -> referent!(cache, fieldtype(type, index)), 1:fieldcount(type))
    end
    cache[type] = answer
    return answer
end

"""
Type of IR value `value` in `ir`, widened to plain type. Library tuple of `cglobal` stays nested `Core.tuple` call,
which `argextype` rejects: it gives tuple of its element types.
"""
function value_type(ir::CC.IRCode, @nospecialize(value::Any))::Any
    nested_tuple(ir, value) && return Tuple{(value_type(ir, element) for element in value.args[2:end])...}
    return CC.widenconst(value_lattice(ir, value))
end

"""
Lattice type of IR `value` in `ir` (`argextype`). Constant binding takes its value in analysis world: `argextype` gives
`Any` when IR world range starts before binding exists (`@invokelatest` reads binding in latest world).
"""
function value_lattice(ir::CC.IRCode, @nospecialize(value::Any))::Any
    value isa GlobalRef && isconst(value) && return Core.Const(getglobal(value.mod, value.name))
    return CC.argextype(value, ir)
end

"""Whether `value` is nested `Core.tuple` call expression inside statement of `ir`."""
function nested_tuple(ir::CC.IRCode, @nospecialize(value::Any))::Bool
    value isa Expr || return false
    value.head === :call || return false
    callee = constant(ir, value.args[1])
    return !isnothing(callee) && something(callee) === Core.tuple
end

"""Constant `value` holds in `ir`: literal, constant global or singleton type instance; `nothing` when not constant."""
function constant(ir::CC.IRCode, @nospecialize(value::Any))::Union{Nothing, Some{Any}}
    type = value_lattice(ir, value)
    type isa Core.Const && return Some{Any}(type.val)
    widened = CC.widenconst(type)
    widened isa DataType && isdefined(widened, :instance) && return Some{Any}(widened.instance)
    return nothing
end

"""Statements that use value of each statement of `ir`."""
function statement_users(ir::CC.IRCode)::Vector{Vector{Int}}
    users = [Int[] for _ in 1:length(ir.stmts)]
    for index in 1:length(ir.stmts), reference in CC.userefs(ir.stmts[index][:stmt])
        used = reference[]
        used isa Core.SSAValue && push!(users[used.id], index)
    end
    return users
end

"""Whether lowered `statement` calls function, directly or as value of slot assignment (`_4 = f(x)`)."""
function call_statement(@nospecialize(statement::Any))::Bool
    statement isa Expr && statement.head === :(=) && (statement = statement.args[2])
    return statement isa Expr && statement.head in (:call, :invoke, :foreigncall)
end
