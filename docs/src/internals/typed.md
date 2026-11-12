# Typed-code rules

Rules that read inferred code: the entry walk, runtime-dispatch candidates, mutation, dispatch, float widening, JET, Float64 operations and non-public access.

```@autodocs
Modules = [CorsetLegacy]
Public = false
Pages = ["entry_walk.jl", "candidates.jl", "mutation.jl", "dispatch.jl", "float_widening.jl", "jet.jl", "float64_scan.jl", "non_public_access.jl", "type_disruption.jl", "type_disruption_fix.jl"]
```

## Entry signatures

`CorsetLegacy.Entries` finds the concrete call signatures a walk starts from. It reads only a `Module`, paths, types and `CorsetLegacy.Membership`.

```@autodocs
Modules = [CorsetLegacy.Entries]
```

## Package membership

`CorsetLegacy.Membership` decides which loaded modules belong to a package: its submodules and its loaded extensions.

```@autodocs
Modules = [CorsetLegacy.Membership]
```
