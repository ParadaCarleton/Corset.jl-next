# runic: off
module LostNarrowingNegative

function head_args(x::Any)
    x isa Expr || return nothing
    x.head === :call || return nothing
    return x.args
end

function call_args(x::Any)
    if x isa Expr && x.head === :call
        return x.args
    end
    return nothing
end

function last_term(x::Any, enabled::Bool)
    (enabled && x isa Expr) || return nothing
    return x.args
end

function known_type(x::Expr)
    (x isa Expr && x.head === :call) || return nothing
    return x.args
end

function first_entry(entries::Union{Nothing, Vector{Int}})
    (entries === nothing || isempty(entries)) && return 0
    return first(entries)
end

function unread(x::Any)
    (x isa Expr && x.head === :call) || return false
    return true
end

function reassigned(x::Any)
    (x isa Expr && x.head === :call) || return nothing
    x = Expr(:block)
    return x.args
end

end
