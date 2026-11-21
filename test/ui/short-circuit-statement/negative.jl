# runic: off
valid(x) = x > 0 && x < 10

function classify(x)
    if x > 0 && x < 10
        return true
    end
    outside = x > 0 || x < -10
    return outside
end

check_all(xs) = foreach(x -> x > 0 || error("bad"), xs)
