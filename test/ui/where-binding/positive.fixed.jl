# runic: off
(same(x::T)::T) where {T} = x
(first_of(v::Vector{T})::T) where T = v[1]
(promoted(x::T)::(T <: Integer ? Int : T)) where {T} = x
