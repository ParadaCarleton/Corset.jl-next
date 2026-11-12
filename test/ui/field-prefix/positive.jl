# runic: off
struct State{T} <: AbstractState
    governor_name::String
    governor_age::Int
    governor_term::T = 4
    budget::Float64
end
