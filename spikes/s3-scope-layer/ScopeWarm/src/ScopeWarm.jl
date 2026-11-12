"""Precompile probe: does a workload remove JuliaLowering first-call compile time?"""
module ScopeWarm
using PrecompileTools: @compile_workload
include("../../overrides.jl")
include("../../scope_facts.jl")
@compile_workload begin
    ScopeFacts.lower_file!(
        ScopeFacts.FormResult[], ScopeFacts.Provenance(), joinpath(@__DIR__, "../../fixtures/script.jl"),
        Module(:Warm); eval_imports = true, full = true
    )
end
end
