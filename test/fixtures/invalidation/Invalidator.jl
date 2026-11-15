# Methods like those DataStructures.jl and SparseArrays.jl add. Each invalidates code that iterates or sizes abstract dict
# or set, reads its value type, or concatenates number and vector.
module Invalidator

struct OddDict{K, V} <: AbstractDict{K, V} end
struct OddSet{T} <: AbstractSet{T} end

Base.iterate(::Union{Base.KeySet{<:Any, <:OddDict}, Base.ValueIterator{<:OddDict}}, state::Int = 1) = nothing
Base.valtype(::OddDict{K, V}) where {K, V} = V
Base.IteratorSize(::Type{<:OddSet}) = Base.SizeUnknown()
Base._cat(dims, first::Union{Number, AbstractVecOrMat{<:Number}}, rest::Union{Number, AbstractVecOrMat{<:Number}}...) = nothing

end
