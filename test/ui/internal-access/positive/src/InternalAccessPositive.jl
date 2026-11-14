# runic: off
"""Uses of other modules' internal names."""
module InternalAccessPositive

import Base: _sub2ind
import Base: unwrapva,isvarargtype
using Base: unwrap_unionall as unwrap

index(dims::Tuple, row::Int) = _sub2ind(dims, row, 1)
body(type::Type) = unwrap(type)
wrapper(type::Type) = Base.rewrap_unionall(type, type)
failed(error::Exception) = error isa Base.Precompilation.PkgPrecompileError
café(type::Type) = Base.isType(type)
inlined(value::Int) = (Base.@_inline_meta; value)
element(type::Type) = unwrapva(type)
opaque(value::Int) = Base.Experimental.@opaque (input -> input)

module Inner
generic(type::Type) = Base.isvarargtype(type)
end

end
