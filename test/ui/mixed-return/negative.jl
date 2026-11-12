# runic: off
function sign_of(x)
    if x < 0
        return -1
    end
    return x == 0 ? 0 : 1
end

function twice(x)
    y = 2x
    y
end

function make()
    helper() = (return 1)
    helper
end

function checked(x)
    x > 0 && return x
    throw(ArgumentError("x must be positive"))
end
