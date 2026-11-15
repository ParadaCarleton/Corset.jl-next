# Methods like those DataStructures.jl adds. Each invalidates code that iterates or sizes abstract dict or set, or reads its value type.
module Invalidator

struct OddDict{K, V} <: AbstractDict{K, V} end
struct OddSet{T} <: AbstractSet{T} end

Base.iterate(::Union{Base.KeySet{<:Any, <:OddDict}, Base.ValueIterator{<:OddDict}}, state::Int = 1) = nothing
Base.valtype(::OddDict{K, V}) where {K, V} = V
Base.IteratorSize(::Type{<:OddSet}) = Base.SizeUnknown()

end
