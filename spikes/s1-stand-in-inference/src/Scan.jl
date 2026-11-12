"""
Infer package methods with stand-ins; classify never-returning calls; run the literal differential.
"""
module Scan

using ..StandIns
const CC = Base.Compiler

export infer_method, classify_bottoms, literal_sites, BottomCall, LiteralSite

const PASS = "CC: COMPACT_1"

"Typed IR before inlining for method `m` at concrete signature `tt`, or a skip reason."
function infer_method(m::Method, tt)::Union{Tuple{CC.IRCode, Any}, Symbol}
    ti, env = ccall(:jl_type_intersection_with_env, Any, (Any, Any), tt, m.sig)::Core.SimpleVector
    ti === Union{} && return :no_intersection
    result = try
        Base.invoke_default_compiler(:typeinf_ircode, CC.NativeInterpreter(), m, ti, env, PASS)
    catch err
        return :inference_error
    end
    ir, rt = result
    ir === nothing && return :inference_refused
    (ir, rt)
end

world() = Base.get_world_counter()

callee(ir::CC.IRCode, x) = (t = CC.argextype(x, ir); t isa CC.Const ? t.val : CC.singleton_type(t))
argtypes(ir::CC.IRCode, args) = Any[CC.argextype(a, ir) for a in args]

"Dispatch status of call type `tt`: `:ok`, `:no_method`, `:ambiguous` or `:partial`."
function dispatch_status(tt)::Symbol
    ms = Base._methods_by_ftype(tt, -1, world())
    (ms === nothing || isempty(ms)) && return :no_method
    any(m -> m.fully_covers, ms) || return :partial
    try
        which(tt); :ok
    catch
        :ambiguous
    end
end

"Return type of `f` on `types`; builtins use their transfer function, keeping constants."
function return_type(f, types::Vector{Any})
    if f isa Core.Builtin
        Base.invoke_default_compiler(:builtin_tfunction, CC.NativeInterpreter(), f, types, nothing)
    else
        try
            Base.infer_return_type(f, Tuple{map(CC.widenconst, types)...})
        catch
            Any
        end
    end
end

model_arg(t) = t isa CC.Const ? (t.val isa NumberStandIn ? CC.Const(t.val.model) : t) : model_type(CC.widenconst(t))

const THROWERS = (throw, error, rethrow, Core.throw_methoderror)
is_thrower(f)::Bool = f in THROWERS || (f isa Function && startswith(string(nameof(f)), "throw")) ||
    (f isa Function && startswith(string(nameof(f)), "_throw"))

"One call inferred `Union{}` and its class."
struct BottomCall
    stmt::Int
    class::Symbol
    callee::String
    args::Vector{Any}
end

"""
Classify every `Union{}` statement. Classes:
explicit_throw, opaque_result, stand_in_gap_<status>, real_<status>, callee_throws, undefined_global, builtin.
`stand_in_gap_*` means the same call on model types (`Float32`, `Int32`, `Array`) returns.
"""
function classify_bottoms(ir::CC.IRCode)::Vector{BottomCall}
    found = BottomCall[]
    for i in 1:length(ir.stmts)
        ir.stmts[i][:type] === Union{} || continue
        stmt = ir.stmts[i][:stmt]
        if stmt isa GlobalRef
            push!(found, BottomCall(i, :undefined_global, string(stmt), Any[])); continue
        end
        stmt isa Expr && stmt.head === :call || continue
        f = callee(ir, stmt.args[1])
        types = argtypes(ir, stmt.args[2:end])
        wide = map(CC.widenconst, types)
        name = f === nothing ? string(stmt.args[1]) : string(f)
        if f !== nothing && is_thrower(f)
            push!(found, BottomCall(i, :explicit_throw, name, wide)); continue
        end
        if any(t -> has_stand_in(t) && (t <: OpaqueResult || occursin("OpaqueResult", string(t))), wide)
            push!(found, BottomCall(i, :opaque_result, name, wide)); continue
        end
        f === nothing && (push!(found, BottomCall(i, :unknown_callee, name, wide)); continue)
        standin = any(has_stand_in, wide)
        if f isa Core.Builtin
            cls = standin && return_type(f, Any[model_arg(t) for t in types]) !== Union{} ? :stand_in_gap_builtin : :builtin
            push!(found, BottomCall(i, cls, name, wide)); continue
        end
        status = dispatch_status(Tuple{typeof(f), wide...})
        if standin
            margs = Any[model_arg(t) for t in types]
            mstatus = dispatch_status(Tuple{typeof(f), map(CC.widenconst, margs)...})
            if mstatus === :ok && return_type(f, margs) !== Union{}
                push!(found, BottomCall(i, Symbol(:stand_in_gap_, status), name, wide)); continue
            end
        end
        cls = status === :ok ? :callee_throws : Symbol(:real_, status)
        push!(found, BottomCall(i, cls, name, wide))
    end
    found
end

"Literal, constant or type name meeting input; result of the differential."
struct LiteralSite
    stmt::Int
    kind::Symbol          # :int_literal, :float_literal, :constant, :type_name
    callee::String
    literal::String
    stand_in::Type
    original::Any         # escaping type as inferred
    counterfactual::Any   # escaping type with literal converted to input type
    escape::Symbol        # :returned, :stored, :intermediate, :no_change
end

literal_value(x) = x isa Number ? Some(x) : x isa QuoteNode && x.value isa Number ? Some(x.value) :
    x isa GlobalRef && isconst(x.mod, x.name) && getglobal(x.mod, x.name) isa Number ? Some(getglobal(x.mod, x.name)) : nothing

"Find literal sites meeting a number stand-in and run the differential on each."
function literal_sites(ir::CC.IRCode)::Vector{LiteralSite}
    sites = LiteralSite[]
    method_stand_ins = unique(filter(!isnothing, [number_stand_in(CC.widenconst(t)) for t in ir.argtypes]))
    for i in 1:length(ir.stmts)
        stmt = ir.stmts[i][:stmt]
        stmt isa Core.PhiNode && append!(sites, phi_sites(ir, i, stmt, method_stand_ins))
        stmt isa Expr && stmt.head === :call || continue
        f = callee(ir, stmt.args[1])
        f === nothing && continue
        args = stmt.args[2:end]
        types = argtypes(ir, args)
        inputs = [number_stand_in(CC.widenconst(t)) for t in types]
        S = something(inputs..., Some(nothing))
        S === nothing && continue
        # Type name applied to input: Float64(x), convert(Float64, x), Int(x).
        T = f isa Type ? f : (f === convert && !isempty(types) && types[1] isa CC.Const ? types[1].val : nothing)
        if T isa Type && T <: Number && isconcretetype(T) && T !== S && !(T <: NumberStandIn) &&
           any(t -> CC.widenconst(t) <: NumberStandIn, types)
            target = T <: AbstractFloat ? FloatStandIn : S === IntStandIn ? IntStandIn : nothing
            target === nothing && continue
            push!(sites, differential(ir, i, (i, 0), :type_name, string(f), string(T), S, target))
            continue
        end
        f isa Core.Builtin && continue
        for (j, a) in enumerate(args)
            v = weak_literal(a)
            v === nothing && continue
            inputs[j] === nothing || continue
            v isa AbstractFloat && S === IntStandIn && continue
            kind = a isa GlobalRef ? :constant : v isa Integer ? :int_literal : :float_literal
            push!(sites, differential(ir, i, (i, j), kind, string(f), repr(v), S, S))
        end
    end
    sites
end

"Number literal or constant eligible as weak value, or `nothing`."
function weak_literal(a)
    lv = literal_value(a)
    lv === nothing && return nothing
    v = something(lv)
    (v isa NumberStandIn || v isa AbstractIrrational || v isa Bool) ? nothing : v
end

literal_phi(ir::CC.IRCode, k::Int, v)::Bool = (st = ir.stmts[k][:stmt]; st isa Core.PhiNode &&
    any(n -> isassigned(st.values, n) && weak_literal(st.values[n]) == v, eachindex(st.values)))

"Statements reachable from `k` through SSA uses, `k` included."
function reachable(ir::CC.IRCode, k::Int)::Set{Int}
    seen = Set([k]); changed = true
    while changed
        changed = false
        for u in 1:length(ir.stmts)
            u in seen && continue
            st = ir.stmts[u][:stmt]
            ops = st isa Expr ? st.args : st isa Core.PhiNode ? [st.values[n] for n in eachindex(st.values) if isassigned(st.values, n)] :
                st isa Core.PiNode ? [st.val] : st isa Core.ReturnNode && isdefined(st, :val) ? [st.val] : []
            any(x -> x isa Core.SSAValue && x.id in seen, ops) && (push!(seen, u); changed = true)
        end
    end
    seen
end

"Literal phi operands (`s = 0` before loop) whose phi value meets a stand-in in some call."
function phi_sites(ir::CC.IRCode, k::Int, phi::Core.PhiNode, stand_ins::Vector)::Vector{LiteralSite}
    out = LiteralSite[]
    meets = any(1:length(ir.stmts)) do u
        st = ir.stmts[u][:stmt]
        st isa Expr && st.head === :call && Core.SSAValue(k) in st.args &&
            any(x -> x !== Core.SSAValue(k) && number_stand_in(CC.widenconst(CC.argextype(x, ir))) !== nothing, st.args[2:end])
    end
    meets || return out
    for n in eachindex(phi.values)
        isassigned(phi.values, n) || continue
        v = weak_literal(phi.values[n])
        v === nothing && continue
        # One source literal appears in several phis (loop head, loop exit); override all reachable copies.
        any(k2 -> k2 < k && literal_phi(ir, k2, v) && k in reachable(ir, k2), 1:k-1) && continue
        slots = [(k2, n2) for k2 in sort!(collect(reachable(ir, k))) if ir.stmts[k2][:stmt] isa Core.PhiNode
                 for n2 in eachindex(ir.stmts[k2][:stmt].values)
                 if isassigned(ir.stmts[k2][:stmt].values, n2) && weak_literal(ir.stmts[k2][:stmt].values[n2]) == v]
        for S in stand_ins
            v isa AbstractFloat && S === IntStandIn && continue
            kind = v isa Integer ? :int_literal : :float_literal
            push!(out, differential(ir, k, slots, kind, "φ", repr(v), S, S))
        end
    end
    out
end

"""
Recompute statement types forward from `site`, with operand `slot` overridden by `override`.
Slot `(k, 0)` overrides statement result; `(k, n)` overrides operand `n`. `nothing` means no override.
"""
function propagate(ir::CC.IRCode, site::Int, slots::Vector{Tuple{Int, Int}}, override)::Dict{Int, Any}
    d = Dict{Int, Any}()
    slot = first(slots)
    operand(k, n, x) = override !== nothing && (k, n) in slots ? override :
        x isa Core.SSAValue && haskey(d, x.id) ? d[x.id] : CC.argextype(x, ir)
    touched(x) = x isa Core.SSAValue && haskey(d, x.id)
    for pass in 1:4, k in 1:length(ir.stmts)
        stmt = ir.stmts[k][:stmt]
        if k == site && slot[2] == 0
            d[k] = override === nothing ? CC.widenconst(ir.stmts[k][:type]) : override
        elseif stmt isa Core.PhiNode
            ns = [n for n in eachindex(stmt.values) if isassigned(stmt.values, n)]
            (k == site || any(s -> s[1] == k, slots) || any(n -> touched(stmt.values[n]), ns)) || continue
            # Optimistic start: back-edge operands not yet computed contribute nothing on pass 1.
            live = [n for n in ns if !(pass == 1 && stmt.values[n] isa Core.SSAValue && stmt.values[n].id > k &&
                                       !haskey(d, stmt.values[n].id))]
            d[k] = reduce(CC.tmerge, (CC.widenconst(operand(k, n, stmt.values[n])) for n in live); init = Union{})
        elseif stmt isa Core.PiNode && touched(stmt.val)
            d[k] = typeintersect(CC.widenconst(operand(k, 1, stmt.val)), CC.widenconst(stmt.typ))
        elseif stmt isa Expr && stmt.head === :call && (k == site || any(touched, stmt.args[2:end]))
            f = callee(ir, stmt.args[1])
            f === nothing && continue
            d[k] = CC.widenconst(return_type(f, Any[operand(k, n, x) for (n, x) in enumerate(stmt.args[2:end])]))
        end
    end
    d
end

"Element or field type a store converts to, or `nothing` when store keeps value type."
function store_target_type(ir::CC.IRCode, f, args)
    T = CC.widenconst(CC.argextype(args[1], ir))
    if f in (setindex!, push!)
        E = T <: AbstractArray ? eltype(T) : Any
        return isconcretetype(E) ? E : nothing
    elseif f in (setfield!, setproperty!) && length(args) >= 2
        name = CC.argextype(args[2], ir)
        name isa CC.Const && T isa DataType && isconcretetype(T) || return nothing
        F = try fieldtype(T, name.val) catch; return nothing end
        return isconcretetype(F) ? F : nothing
    end
    nothing
end

"Differential on one site: compare escaping types with and without the override."
function differential(ir::CC.IRCode, site::Int, slot::Union{Tuple{Int, Int}, Vector{Tuple{Int, Int}}}, kind::Symbol, fname::String, lit::String,
                      S::Type, override)::LiteralSite
    slots = slot isa Tuple ? [slot] : slot
    orig = propagate(ir, site, slots, nothing)
    cf = propagate(ir, site, slots, override)
    get(orig, site, nothing) == get(cf, site, nothing) &&
        return LiteralSite(site, kind, fname, lit, S, get(orig, site, Any), get(cf, site, Any), :no_change)
    # Conversion that breaks the call (index, field number) means literal is no number operand.
    get(cf, site, Any) in (Any, Union{}) &&
        return LiteralSite(site, kind, fname, lit, S, get(orig, site, Any), get(cf, site, Any), :not_operand)
    escape, eo, ec = :intermediate, orig[site], cf[site]
    for k in 1:length(ir.stmts)
        stmt = ir.stmts[k][:stmt]
        if stmt isa Core.ReturnNode && isdefined(stmt, :val) && stmt.val isa Core.SSAValue &&
           haskey(cf, stmt.val.id) && cf[stmt.val.id] != orig[stmt.val.id]
            return LiteralSite(site, kind, fname, lit, S, orig[stmt.val.id], cf[stmt.val.id], :returned)
        elseif stmt isa Expr && stmt.head === :call && length(stmt.args) >= 3 && stmt.args[2] isa Core.Argument
            f = callee(ir, stmt.args[1])
            f in (setindex!, setfield!, setproperty!, push!) || continue
            v = f in (setfield!, setproperty!) ? stmt.args[min(4, end)] : stmt.args[3]
            v isa Core.SSAValue && haskey(cf, v.id) && cf[v.id] != orig[v.id] || continue
            store_target_type(ir, f, stmt.args[2:end]) === nothing || continue
            escape, eo, ec = :stored, orig[v.id], cf[v.id]
        end
    end
    LiteralSite(site, kind, fname, lit, S, eo, ec, escape)
end

"Source line of statement `i`, best effort."
function stmt_line(ir::CC.IRCode, i::Int)::String
    try
        stack = Base.IRShow.buildLineInfoNode(ir.debuginfo, nothing, i)
        isempty(stack) && return "?"
        node = last(stack)
        string(node.file, ":", node.line)
    catch
        "?"
    end
end
export stmt_line

end
