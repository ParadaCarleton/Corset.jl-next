# runic: off
function define_and_call()
    @eval helper() = 1
    return helper()
end

function define_and_call_kw()
    eval(:(scaled(x; by) = x * by))
    @eval function scaled(x; by)
        x * by
    end
    return scaled(2; by = 3)
end

function define_generic()
    @eval wrap(x::T) where {T} = x
    return wrap(1)
end

function define_and_set()
    @eval set_flag(flag) = flag
    return set_flag((flag = true))
end

function define_qualified()
    Base.@eval qualified() = 1
    return qualified()
end
