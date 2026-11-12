# runic: off
function define_and_call()
    @eval helper() = 1
    return Base.invokelatest(helper)
end

function define_and_call_kw()
    eval(:(scaled(x; by) = x * by))
    @eval function scaled(x; by)
        x * by
    end
    return scaled(2; by = 3)
end
