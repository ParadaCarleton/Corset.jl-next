# runic: off
elementtype(f, x) = Core.Compiler.return_type(f, Tuple{typeof(x)})
result_type(op, a, b) = Base.promote_op(op, eltype(a), eltype(b))
