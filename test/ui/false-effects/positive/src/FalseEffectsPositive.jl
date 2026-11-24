# runic: off
module FalseEffectsPositive

const CALLS = Ref(0)
const SCALE = Ref(2.0)

Base.@assume_effects :effect_free function scaled(x::Float64)
    CALLS[] += 1
    return 2x
end

Base.@assume_effects :inaccessiblememonly function rescaled(x::Float64)
    return SCALE[] * x
end

Base.@assume_effects :notaskstate function noisy(x::Float64)
    return x + rand()
end

end
