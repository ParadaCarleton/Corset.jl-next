# Analysis code takes values of checked program, so method that specializes on them compiles again for each new value
# type: precompile workload cannot cover them. Parameter typed `Any` in analysis module carries `@nospecialize`.

using Test: @test, @testset
using Corset: Corset

const ANALYSIS = (Corset.Effects, Corset.Inference, Corset.Widening, Corset.StandIns)
# Iterable parameters: few element types, and specialization keeps loop over them static.
const ITERABLE = (:union_targets, :with_swaps, :add_parameters!)

"""Whether parameter at `position` of `method` signature (method itself at 1) carries `@nospecialize`."""
nospecialized(method::Method, position::Int)::Bool = method.nospecialize & (1 << (position - 2)) != 0

"""File, line and name of each analysis method with parameter typed `Any` and no `@nospecialize`."""
function specializing_methods()::Vector{String}
    found = String[]
    for holder in ANALYSIS, name in names(holder; all = true)
        (name in ITERABLE || startswith(string(name), '#') || !isdefined(holder, name)) && continue
        callable = getfield(holder, name)
        callable isa Function || continue
        for method in methods(callable)
            parentmodule(method) === holder || continue
            parameters = Base.unwrap_unionall(method.sig).parameters
            for position in 2:length(parameters)
                parameters[position] === Any && !nospecialized(method, position) && push!(found, "$(method.file):$(method.line) $name")
            end
        end
    end
    return unique!(found)
end

@testset "specialization on program values" begin
    @test nospecialized(only(methods(Corset.Effects.Summaries.value_targets!)), 3) && !nospecialized(only(methods(Corset.Effects.Summaries.value_targets!)), 2)
    @test isempty(specializing_methods())
end
