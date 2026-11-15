# runic: off
"""Package whose public structs have no abstract supertype."""
module ClosedStructPositive

export Model, Counter, Positive, Circle, Grid, Options, Rebuilt
public Point, Tagged, Shapes

"""Linear model."""
struct Model
    weights::Vector{Float64}
end

"""Point in plane."""
struct Point{T}
    x::T
    y::T
end

"""Mutable counter."""
mutable struct Counter
    count::Int
end

"""Positive integer, checked by inner constructor."""
struct Positive
    value::Int
    Positive(value::Int) = value > 0 ? new(value) : throw(DomainError(value))
end

"""Identifier tagged with type that no field holds."""
struct Tagged{T}
    id::Int
end

"""Table that public alias `Grid` makes public."""
struct Table{T}
    rows::Vector{T}
end

const Grid = Table{Int}

"""Options with keyword constructor."""
Base.@kwdef struct Options
    verbose::Bool = false
end

"""Rebuild struct `definition` with line of this macro, as `ConcreteStructs.@concrete` does."""
macro rebuilt(definition)
    fields = filter(field -> !(field isa LineNumberNode), definition.args[3].args)
    return esc(Expr(:struct, definition.args[1], definition.args[2], Expr(:block, LineNumberNode(@__LINE__, Symbol(@__FILE__)), fields...)))
end

"""Size whose constructors carry macro line, so struct ties by name."""
@rebuilt struct Rebuilt
    size::Int
end

# Branch Julia never runs defines no struct; `Counter` stays tied to its definition alone.
@static if VERSION < v"1.6"
    struct Counter end
end

"""Public submodule; parent also exports its `Circle`."""
module Shapes
    public Marker

    """Shape without fields; its constructor starts on its line."""
    struct Marker end

    """Circle by radius."""
    struct Circle
        radius::Float64
    end
end

using .Shapes: Circle

"""Older shapes: private `Circle` shares name and file with public one."""
module Legacy
"""Circle by diameter."""
struct Circle
    diameter::Float64
end
end

# Constructor of public `Model` shares line with private struct.
Model() = Model(Float64[]); struct Spacer end

include("internal.jl")

@static if VERSION < v"1.6"
    include("compat.jl")
end

end
