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
include("Engine.jl")
include("Render.jl")

using .Engine: check

end
