# Diagnostics

Scripts that explain effects results. They measure nothing and pass nothing; `benchmark/` holds measurements.

Each script reads work directory `<work>` that `benchmark/effects.jl` makes:

```sh
julia benchmark/effects.jl . <work> Distributions@0.25.135   # makes <work>/env-Distributions and <work>/Distributions
```

| Script | Use when |
|---|---|
| `audit.jl` | Gate hand audit (`phase5.md`, row 5). Lists definite writes that Base contract or join starts, with chain and source. |
| `census.jl` | `possible` share is high. Traces each `possible` write to statement that starts it; groups by source. |
| `dump_facts.jl` | Two runs may differ (rebuild, Julia version, branch). Writes facts as sorted text; optional summary dump. |
| `summary_leaves.jl` | Two summary dumps differ. Finds variants where difference starts. |

`benchmark/determinism.jl` repeats `dump_facts.jl` over fresh compiles of target package (gate: facts stay same).

- Run scripts on boxes (`boxrun`). Each script infers target package cold: minutes for large packages.
- `census.jl` counts methods with units; benchmark counts methods with facts. Counts differ by a few percent.
- Compare fact dumps from separate environments as sets, never as one pair: each environment compiles target separately.
