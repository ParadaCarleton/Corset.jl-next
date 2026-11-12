# runic: off
function sign_of(x)
    if x < 0
        return -1
    end
    return x == 0 ? 0 : 1
end

function find_first(xs)
    for x in xs
        x > 0 && return x
    end
    return nothing
end
