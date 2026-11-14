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

function define_twice()
    @eval twice() = 1
    twice()::Int = 2
    return nothing
end

# Eval into other module defines `runner.include`; `Base.include` and own `include` are other functions.
function load_runner(runner::Module, path::String)
    Core.eval(runner, :(include(path::AbstractString) = Base.include($runner, path)))
    Base.include(runner, path)
    return include(path)
end
