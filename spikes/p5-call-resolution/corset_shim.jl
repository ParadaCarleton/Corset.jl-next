# Stand-in signatures from rewrite `src/` (`Signatures.method_signatures`), loaded only for S5_ROOTS=standin:
# stand-in methods on Base functions change dispatch candidates, so declared mode must not see them.
const CORSET_SRC = get(ENV, "CORSET_SRC", joinpath(@__DIR__, "..", "..", "src"))  # rewrite `src/`
module Facts
    tuple_parameters(type::Type)::Core.SimpleVector = Base.unwrap_unionall(type).parameters
end
include(joinpath(CORSET_SRC, "StandIns.jl"))
include(joinpath(CORSET_SRC, "Signatures.jl"))
