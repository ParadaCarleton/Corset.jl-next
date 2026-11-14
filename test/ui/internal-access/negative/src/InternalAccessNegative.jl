# runic: off
"""Public names and own internal names."""
module InternalAccessNegative

using Base.Iterators: flatten
using Base: Fix1
# Stale import of public name.
using Base: Fix2

pairs_of(lists::Vector) = collect(flatten(lists))
workers() = Base.Threads.nthreads()
add_one(values::Vector{Int}) = map(Fix1(+, 1), values)
helper(value::Int) = value
# Self-qualified access: own name.
again(value::Int) = InternalAccessNegative.helper(value)

module Inner
using ..InternalAccessNegative: helper
twice(value::Int) = 2 * helper(value)
outer(value::Int) = Main.InternalAccessNegative.helper(value)
end

end
