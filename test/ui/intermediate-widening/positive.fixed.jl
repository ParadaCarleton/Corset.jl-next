# ==> src/IntermediateWideningPositive.jl
# runic: off
module IntermediateWideningPositive

half32(x::AbstractFloat) = Float32(x * oftype(x, 0.5))

function record!(log::Vector{Float32}, x::AbstractFloat)
    log[1] = x * oftype(x, 2.0)
    return nothing
end

end
