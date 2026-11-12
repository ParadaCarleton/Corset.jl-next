# runic: off
function scale(v, s; f = identity)
    w = s .* v
    for x in w
        total += f(x)
    end
    return w
end

n = length(items)
