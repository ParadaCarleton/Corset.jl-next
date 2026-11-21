# runic: off
function check(x)
    x > 0 || throw(DomainError(x))
    return nothing
end

check_all(xs) = foreach(x -> x > 0 || error("bad"), xs)

map([1]) do x
    x > 0 || error("bad")
end

bounded(x) = x > 0 && x < 10

function skip_negative(xs)
    for x in xs
        x > 0 || continue
    end
end

fallback(x) = x > 0 ? x : throw(DomainError(x))
