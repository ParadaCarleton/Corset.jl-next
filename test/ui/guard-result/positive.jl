# runic: off
check(x) = x > 0 || throw(DomainError(x))

function validate(x)
    isnothing(x) && return
end

function ensure(x)
    if x > 0
        x < 10 || error("too large")
    else
        error("not positive")
    end
end
