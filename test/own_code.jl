# Checks of loaded Corset code that self-lint cannot run yet.
# Boxed captures: closure over variable lowering cannot prove single assignment gets `Core.Box` and type `Any`.
# `@match` expands to `@goto`, so closure in function with `@match` boxes what it captures (F57 not in self-lint).

using Test: @test, @testset
using Corset: Corset

"""Whether lowered `statement` makes `Core.Box`, directly or as right side of assignment."""
function boxes(statement::Any)::Bool
    statement isa Expr || return false
    statement.head === :(=) && return boxes(statement.args[2])
    return statement.head in (:new, :call) && any(argument -> argument == GlobalRef(Core, :Box) || argument === Core.Box, statement.args)
end

"""`root` and every submodule it defines, depth first."""
function modules_of(root::Module)::Vector{Module}
    found = Module[root]
    for name in names(root; all = true)
        isdefined(root, name) || continue
        child = getfield(root, name)
        child isa Module && child !== root && parentmodule(child) === root && append!(found, modules_of(child))
    end
    return found
end

"""File and line of each Corset method whose lowered code boxes captured variable."""
function boxed_methods()::Vector{String}
    found = String[]
    for holder in modules_of(Corset), name in names(holder; all = true)
        isdefined(holder, name) || continue
        callable = getfield(holder, name)
        callable isa Function || continue
        for method in methods(callable)
            parentmodule(method) === holder || continue
            any(boxes, Base.uncompressed_ast(method).code) && push!(found, "$(method.file):$(method.line)")
        end
    end
    return unique!(found)
end

"""
Name of each constant that Corset defines twice in one module. Julia keeps last value without warning, so code
of first file reads table of second.
"""
function redefined_constants()::Vector{String}
    found = String[]
    for holder in modules_of(Corset), name in names(holder; all = true)
        partition = convert(Core.Binding, GlobalRef(holder, name)).partitions
        count = 0
        while !isnothing(partition)
            count += Base.binding_kind(partition) == Base.PARTITION_KIND_CONST
            partition = isdefined(partition, :next) ? partition.next : nothing
        end
        count > 1 && push!(found, "$holder.$name")
    end
    return found
end

@testset "constant redefinitions" begin
    @test isempty(redefined_constants())
end

@testset "boxed captures" begin
    @test boxes(Expr(:(=), Core.SlotNumber(2), Expr(:new, GlobalRef(Core, :Box)))) && !boxes(Expr(:call, GlobalRef(Base, :sum)))
    @test isempty(boxed_methods())
end
