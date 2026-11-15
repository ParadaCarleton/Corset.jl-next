# Methods like those DataStructures.jl, SparseArrays.jl and ChainRulesCore.jl add. Each invalidates code that iterates or
# sizes abstract dict or set, reads its value type, concatenates number and vector, or promotes abstract number.
module Invalidator

struct OddDict{K, V} <: AbstractDict{K, V} end
struct OddSet{T} <: AbstractSet{T} end
struct OddZero end

Base.iterate(::Union{Base.KeySet{<:Any, <:OddDict}, Base.ValueIterator{<:OddDict}}, state::Int = 1) = nothing
Base.valtype(::OddDict{K, V}) where {K, V} = V
Base.IteratorSize(::Type{<:OddSet}) = Base.SizeUnknown()
Base._cat(dims, first::Union{Number, AbstractVecOrMat{<:Number}}, rest::Union{Number, AbstractVecOrMat{<:Number}}...) = nothing
Base.promote_rule(::Type{<:Number}, ::Type{OddZero}) = Number

end
