"""Syntax-macro stand-ins for common Base macros; keep byte provenance and scope, drop metadata.
Use only for fact extraction: expansions are wrong for code generation."""
module Overrides

using JuliaLowering: JuliaLowering as JL, MacroContext, SyntaxTree, @ast

"""Expand to last argument, or empty block when macro has no arguments."""
passthrough(ctx::MacroContext, exs::SyntaxTree...)::SyntaxTree =
    isempty(exs) ? (@ast ctx ctx.macrocall [:block]) : exs[end]

"""Expand to first argument (`@assert cond msg` keeps `cond`)."""
first_arg(ctx::MacroContext, exs::SyntaxTree...)::SyntaxTree = exs[1]

"""Expand `@doc str def` to `def`; signature-only docs bind nothing and expand to empty block."""
function doc(ctx::MacroContext, exs::SyntaxTree...)::SyntaxTree
    target = exs[end]
    JL.head(target) in (:call, :where) ? (@ast ctx ctx.macrocall [:block]) : passthrough(ctx, exs...)
end
(::typeof(Core.var"@doc"))(ctx::MacroContext, exs::SyntaxTree...) = doc(ctx, exs...)

for m in (Base.var"@inline", Base.var"@noinline", Base.var"@inbounds", Base.var"@propagate_inbounds",
          Base.var"@simd", Base.var"@views", Base.var"@boundscheck", Base.var"@fastmath")
    @eval (::typeof($m))(ctx::MacroContext, exs::SyntaxTree...) = passthrough(ctx, exs...)
end
(::typeof(Base.var"@assert"))(ctx::MacroContext, exs::SyntaxTree...) = first_arg(ctx, exs...)

end
