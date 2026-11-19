# Corset

Corset is a code-quality checker for Julia. It reports likely bugs, performance traps and code that is hard to read.
Each finding shows the code, the reason and a fix. Corset applies the fixes that are safe for your project.

```text
error[nan-compare]: `x != NaN` is never false
 --> demo.jl:2:21
  |
2 | valid = filter(x -> x != NaN, samples)
  |                     ^^^^^^^^ NaN equals no value, itself included
  |
  = why: IEEE comparison with NaN is false, and `!=` is true
  = fix: replace with `!isnan(x)`   [likely]
  = docs: corset explain nan-compare
  = note: deny from correctness group, script preset
  = note: opt out with `# corset: allow nan-compare -- <reason>`
```

## Install

Corset is not in the General registry. Add the `corset` app from this repository:

```julia
pkg> app add https://github.com/ParadaCarleton/Corset.jl-next
```

Pkg puts the app in `~/.julia/bin`. Add that directory to `PATH`.

## Use

```bash
corset check            # report findings
corset fix              # apply fixes up to the fix tier of the project
corset baseline         # record current findings in corset-baseline.toml
corset explain <rule>   # print the documentation of a rule
```

A package sets its kind in `Project.toml`:

```toml
[preferences.Corset]
kind = "library"
```

The [guide](docs/src/guide.md) tells how to set levels, opt out of a rule and adopt Corset with a baseline.

## Acknowledgments

- [Clippy](https://github.com/rust-lang/rust-clippy) and the Rust compiler set the model for Corset: lint levels, opt-out comments, UI snapshot tests, `explain` pages and the message format.
- [JuliaSyntax.jl](https://github.com/JuliaLang/JuliaSyntax.jl) parses source into the lossless tree that rules and fixes use.
- [Argus.jl](https://github.com/iuliadmtru/Argus.jl) matches syntax patterns.
- [ReLint.jl](https://github.com/RelationalAI-oss/ReLint.jl) and LintApp.jl in [JuliaWorkspaces.jl](https://github.com/julia-vscode/JuliaWorkspaces.jl) are sources of rules, and references for the tests.

## License

Corset is free for noncommercial use under [PolyForm Noncommercial 1.0.0](LICENSE).
Universities, public research institutes and other noncommercial organizations qualify, whatever their funding.
Commercial use needs a separate license; contact [ParadaCarleton](https://github.com/ParadaCarleton).
Legacy Corset (v0.3.0 and earlier) lives at [ParadaCarleton/Corset.jl](https://github.com/ParadaCarleton/Corset.jl) under MPL 2.0.
