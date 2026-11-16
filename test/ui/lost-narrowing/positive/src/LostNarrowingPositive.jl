# runic: off
module LostNarrowingPositive

function head_args(x::Any)
    (x isa Expr && x.head === :call) || return nothing
    return x.args
end

function block_length(x::Any)
    if !(x isa Expr && x.head === :block)
        return 0
    end
    return length(x.args)
end

function counted_args(x::Any, limit::Int)
    (limit > 0 && x isa Expr && length(x.args) <= limit) || return nothing
    return x.args
end

function second_entry(entries::Union{Nothing, Vector{Float64}})
    (!isnothing(entries) && length(entries) > 1) || return 0.0
    return entries[2]
end

function call_heads(items::Vector{Any})
    heads = Symbol[]
    for item in items
        (item isa Expr && item.head === :call && !isempty(item.args)) || continue
        push!(heads, item.head)
    end
    return heads
end

function stored_test(x::Any)
    called = x isa Expr && x.head === :call
    called || return nothing
    return x.args
end

function stored_or(entries::Union{Nothing, Vector{Int}})
    missing_entries = entries === nothing || isempty(entries)
    missing_entries && return 0
    return first(entries)
end

function used_guard(x::Any)
    called = (x isa Expr && x.head === :call) || return nothing
    return called ? x.args : nothing
end

function block_value(x::Any)
    outcome = begin
        if !(x isa Expr && x.head === :call)
            return nothing
        end
    end
    return isnothing(outcome) ? x.args : nothing
end

function commented(x::Any)
    (x isa Expr &&  # call form only
        x.head === :call) || return nothing
    return x.args
end

reject(x) = throw(ArgumentError("not a call: $x"))

function checked_args(x::Any)
    (x isa Expr && x.head === :call) || reject(x)
    return x.args
end

end
