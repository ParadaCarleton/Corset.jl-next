# runic: off
module FalseEffectsNegative

const CALLS = Ref(0)
const TABLE = (1.0, 2.0, 3.0)

Base.@assume_effects :effect_free function doubled(x::Float64)
    return 2x
end

Base.@assume_effects :consistent function lookup(index::Int)
    return TABLE[index]
end

# Rule cannot check `:nothrow`.
Base.@assume_effects :nothrow function half(x::Float64)
    CALLS[] += 1
    return x / 2
end

# Rule cannot check `:consistent`: read value can miss result.
const SCALE = Ref(2.0)
Base.@assume_effects :consistent function rescaled(x::Float64)
    return SCALE[] * x
end

# Task argument is plain memory: `:notaskstate` allows its fields.
Base.@assume_effects :notaskstate function unstick!(task::Task)
    task.sticky = false
    return task
end

# Method without claim.
function counted(x::Float64)
    CALLS[] += 1
    return x
end

end
