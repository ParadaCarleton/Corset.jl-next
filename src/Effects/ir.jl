"""
IR of inference `frame` before inlining, and source statement index of each IR statement (`effects.md`, IR). Passes run
on copies, so frame stays as `inference` stage left it. Line of each statement carries its index through passes.
Compaction keeps statements `kept` marks, though compiler effects let it delete them.
"""
function frame_ir(frame::CC.InferenceState, interpreter::CC.NativeInterpreter, kept::Vector{Bool})::Tuple{CC.IRCode, Vector{Int}}
    source = copy(frame.src)
    count = length(source.code)
    for index in findall(kept)
        source.ssaflags[index] &= ~CC.IR_FLAG_EFFECT_FREE
    end
    stream = CC.DebugInfoStream(Int32[part for index in 1:count for part in (index, 0, 0)])
    stream.def = frame.linfo
    source.debuginfo = Core.DebugInfo(stream, count)
    # Conversion edits control flow and statement info in place; `slot2reg` truncates slot types.
    optimization = CC.OptimizationState(
        frame.linfo, source, nothing, copy(frame.stmt_info), frame.mod, frame.sptypes, copy(frame.slottypes),
        CC.InliningState(frame, interpreter), deepcopy(frame.cfg), frame.unreachable, frame.bb_vartables, frame.insert_coverage,
    )
    ir = CC.run_passes_ipo_safe(source, optimization, "CC: COMPACT_1")
    return ir, [Int(ir.stmts[index][:line][1]) for index in 1:length(ir.stmts)]
end

"""IR `ir` with argument types of `constants` (position and value) set to constant; statements stay shared."""
function specialize(ir::CC.IRCode, constants::Vector{Pair{Int, Any}})::CC.IRCode
    isempty(constants) && return ir
    argtypes = copy(ir.argtypes)
    foreach(((position, value),) -> argtypes[position] = Core.Const(value), constants)
    return CC.IRCode(ir.stmts, ir.cfg, ir.debuginfo, argtypes, ir.meta, ir.sptypes, ir.valid_worlds)
end

"""Types whose values point to no object Corset tracks: type objects, modules, symbols and strings."""
const PLAIN = Union{Type, Core.TypeName, Module, Symbol, String, Core.MethodInstance, Method}

"""
Whether value of `type` can point to object effects can reach: mutable, abstract, `Ptr`, or holds such field. `cache`
keeps answers; recursive struct counts as pointing.
"""
function referent!(cache::IdDict{Any, Bool}, type::Any)::Bool
    haskey(cache, type) && return cache[type]
    cache[type] = true
    answer = if type === Union{}
        false
    elseif type isa Union
        referent!(cache, type.a) || referent!(cache, type.b)
    elseif type isa UnionAll || !(type isa DataType) || !isconcretetype(type)
        !(type <: PLAIN)
    elseif type <: PLAIN
        false
    elseif type <: Ptr || ismutabletype(type)
        true
    else
        any(field -> referent!(cache, field), fieldtypes(type))
    end
    cache[type] = answer
    return answer
end

"""Type of IR value `value` in `ir`, widened to plain type."""
value_type(ir::CC.IRCode, value::Any)::Any = CC.widenconst(CC.argextype(value, ir))

"""Constant `value` holds in `ir`: literal, constant global or singleton type instance; `nothing` when not constant."""
function constant(ir::CC.IRCode, value::Any)::Union{Nothing, Some{Any}}
    type = CC.argextype(value, ir)
    type isa Core.Const && return Some(type.val)
    widened = CC.widenconst(type)
    widened isa DataType && isdefined(widened, :instance) && return Some(widened.instance)
    return nothing
end

"""Whether `type` is tuple type with definite field count: no `Vararg` parameter."""
definite_tuple(type::Any)::Bool = type isa DataType && type <: Tuple && (isempty(type.parameters) || !Base.isvarargtype(type.parameters[end]))
