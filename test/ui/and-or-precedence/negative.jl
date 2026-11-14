# runic: off
function first_value(state, values)
    (state === nothing || values === nothing) && return nothing
    return first(values)
end
grouped(a, b, c) = a || (b && c)
guard(a, b) = a && b || return
plain(a, b) = a || b
both(a, b, c) = a && b && c
spaced(a, b, c) = a || ( b && c )
middle_grouped(a, b, c, d) = a || (b && c) || d
tail_and(a, b, c, d) = (a || b) && c || d
grouped_chain(a, b, c, d) = a || (b && c || d)
