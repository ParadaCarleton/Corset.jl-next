# runic: off
function first_value(state, values)
    state === nothing || (values === nothing && return nothing)
    return first(values)
end
ready(a, b, c) = a || (b && c)
chained(a, b, c, d) = a || b || (c && d)
grouped_whole(a, b, c) = (a || (b && c)) && return true
nested(a, b, c, d) = d && (a || (b && c))
