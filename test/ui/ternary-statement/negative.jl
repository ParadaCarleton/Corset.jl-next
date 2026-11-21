# runic: off
sign_label(x) = x > 0 ? "positive" : "negative"

function pick(flag, a, b)
    picked = flag ? a : b
    return picked
end

function last_value(flag)
    flag ? 1 : 2
end

clamp_all(xs) = map(x -> x > 0 ? x : zero(x), xs)

branch_value(flag, other) = if flag
    1
else
    other ? 2 : 3
end
