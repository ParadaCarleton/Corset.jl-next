"""
`internal-access` (F66): code reaches name other module neither exports nor declares `public`.

## Description
Reports qualified access as `Base._sub2ind(…)` and import as `import Base: _sub2ind` of internal name.
ExplicitImports.jl finds them. Chain as `Base.Precompilation.PkgPrecompileError` reports once.
Access to own package passes, submodules and extensions included.

## Rationale
Owner may rename or remove internal name in any release, with no breaking-change notice.

## Example
```julia
position(dims::Tuple, row::Int, column::Int) = Base._sub2ind(dims, row, column)
```

## Alternative
```julia
position(dims::Tuple, row::Int, column::Int) = LinearIndices(dims)[row, column]
```

## Limitations
Renamed import (`using Base: unwrap_unionall as unwrap`) passes: ExplicitImports.jl does not report it.
Module ExplicitImports.jl cannot analyze fully (dynamic `include`, module macro writes) reports qualified accesses only.
"""
module InternalAccess

using ...Facts

const NAME = Symbol("internal-access")

"""Findings for each internal access, at name or name chain."""
function findings(facts::FactSet)::Vector{Finding}
    external = facts.external
    isnothing(external) && return Finding[]
    return map(external.internal_accesses) do access
        return Finding(
            NAME, :internal_access, Confidence.definite, "`$(access.owner).$(access.name)` is internal to `$(access.owner)`",
            Label(access.span, access.imported ? "imports internal name" : "reaches internal name"), Label[],
            "owner may rename or remove internal name in any release", manual_fix("use public API, or ask `$(access.owner)` to declare name `public`"),
        )
    end
end

const ENTRY = RuleEntry(NAME, Group.composability, [66], Stage.external, findings)

end
