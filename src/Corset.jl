"""
Julia code-quality checker; rewrite in progress. Legacy implementation lives in `lib/CorsetLegacy`.

Layers build facts (`Facts`), rules turn facts into findings (`Rules`), `Engine` runs them.
"""
module Corset

include("Facts.jl")
include("Syntax.jl")
include("Rules.jl")
include("Render.jl")
include("Fixes.jl")
include("Engine.jl")

using .Engine: check

end
