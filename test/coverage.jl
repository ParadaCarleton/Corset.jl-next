# Coverage helper that `effects.jl` and `names.jl` share. Each test file includes it in own module.

"""Whether coverage run instruments `path`: its counters are effects, so compiler proves no `effect_free` there."""
function instrumented(path::String)::Bool
    mode = Base.JLOptions().code_coverage
    mode in 0:3 || error("unknown coverage mode $mode")
    return mode in (1, 2) || mode == 3 && startswith(path, unsafe_string(Base.JLOptions().tracked_path))
end
