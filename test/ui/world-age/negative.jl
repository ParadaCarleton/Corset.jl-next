# runic: off
function define_and_call()
    @eval helper() = 1
    return Base.invokelatest(helper)
end

@eval helper2() = 2
helper2()

function no_eval()
    @eval x = 1
    return other()
end
