(same(x::T)::T) where {T} = x
function first_of(v::Vector{T})::T where {T}
    return v[1]
end
make(::Type{T}) where {T} = T()
