"""
Julia code-quality checker; rewrite in progress. Legacy implementation lives in `lib/CorsetLegacy`.

Stages build facts (`Facts`), rules turn facts into findings (`Rules`), `Config` sets levels, `Engine` runs them.
"""
module Corset

include("Facts.jl")
include("Syntax.jl")
include("Rules.jl")
include("Config.jl")
include("Fixes.jl")
include("OptOuts.jl")
include("Baseline.jl")
include("Engine.jl")
include("Render.jl")
include("Output.jl")
include("CLI.jl")

using .Engine: check

"""Command-line entry point for `corset` app and `julia -m Corset`."""
function (@main)(args::Vector{String})::Int
    return CLI.execute(args, stdout, stderr)
end

end
