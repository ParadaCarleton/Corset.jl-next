# Changelog

## Unreleased

- Corset loads a package to check it. The `corset` command builds a temporary environment and runs again inside it.
- The temporary environment starts from the package Manifest and adds the test dependencies. A version change is a configuration error.
- A package that throws while loading gets a `load-error` finding. Rules that read the loaded package do not run.
- Corset loads the trigger packages of each extension, so rules see the extension. An extension that throws gets a `load-error` finding.
- New rule `shadowed-base`: a method named like an exported Base function defines a new function.
- New rule `method-overwrite`: a later method definition replaces an earlier one with the same positional signature.
- New rule `untested-extension`: the test dependencies leave out a trigger package of an extension.
- New rule `operator-consistency`: `==` or `isequal` without a matching `hash`, and a method on `!=`, `>` or `>=`.
- Method sites of operators written in parentheses, as in `Base.:(==)`, get exact spans.
- New rule `invariant-parameter`: an abstract type parameter in an argument type, as in `Vector{Real}`, rejects `Vector{Float64}`. The fix writes `Vector{<:Real}`.
- New rule `closed-struct`: a public struct has no abstract supertype, so users cannot add a sibling type.
- New rule `iterator-traits`: a type with `iterate` and no `eltype` makes `collect` build `Vector{Any}`.
- New rule `missing-interface`: a struct misses a method that the `AbstractArray`, `AbstractString` or iteration interface requires.
- New rule `overspecified-type`: an argument of a public function names `Float64`, `Int`, `AbstractFloat` or a concrete container such as `Vector`. The fix writes the abstract type, as in `AbstractVector{<:Real}`.
- New rule `method-ambiguity`: two package methods match the same call, and neither is more specific. `Test.detect_ambiguities` finds the pairs. The message names a call that matches both.
- `method-overwrite` messages show the `where` type variables of the signature.
- Corset keeps a disk cache of analyses in the Julia depot. A rerun with no change reads the cache and loads no package. `--no-cache` turns the cache off.
- New rule `never-succeeds`: inference proves that a call never returns. No method matches, a field is missing, or the callee always throws.
- The `inference` stage keeps its results per method in the disk cache. A rerun after an edit infers only the changed methods and the methods that read their code.
- New rule `piracy`: a package method extends a function of another module, and another module owns every argument type. Aqua.jl decides piracy. Extensions own the package types.
- New rule `internal-access`: code reaches a name that another module neither exports nor declares `public`, as in `Base._sub2ind`. ExplicitImports.jl finds the accesses and imports.
- New rule `implicit-import`: a bare `using X` brings names the module uses without naming them. The fix writes `using X: X, name, …`.
- New rule `misplaced-import`: an explicit import sits in a file that uses none of its names, and one other file uses them all. The fix moves the import to the top of that file.
- `corset fix` applies a fix that edits several files to all of them or to none.
- New rule `unused-import`: an explicit import binds a name that its module never uses. The fix removes the name, or the whole statement.
- Import rules skip a statement when a use of its names sits in a file outside the checked files, as in `corset check src/one.jl`.
- `implicit-import` labels the first use of each name in source order, and labels a string macro use such as `md"…"`; before, an import of a string macro stopped the check.
- A cause label in another file than the primary label gets its own snippet in text output.
- A `[sources]` entry in `test/Project.toml` can give `rev` alone or `subdir`.
- Text output shows paths relative to the project root.
- A precompile workload compiles the command line, so a first `corset check` starts in seconds.

## 0.5.0

Corset 0.5 is a rewrite. The rule names, opt-out comments, baseline file and Julia API of 0.4 are gone.

- Breaking: rules read the syntax tree of each file. Rules that read the loaded module or inferred types are not in this release.
- Breaking: the `corset` app has the commands `check`, `fix`, `baseline` and `explain`. Exit codes follow Cargo.
- Breaking: configuration lives in `[preferences.Corset]` with the keys `kind`, `confidence`, `fix_tier`, `levels` and `banned`. `LocalPreferences.toml` overrides it.
- Breaking: opt-out comments are `# corset: allow <rule> -- <reason>` and `# corset: allow-file <rule> -- <reason>`. Each needs a reason.
- Breaking: the baseline file is `corset-baseline.toml`. Its entries have no line numbers.
- Breaking: the license is PolyForm Noncommercial 1.0.0.
- 31 rules in four groups: `correctness`, `performance`, `composability` and `readability`. The project kind sets the level of each group.
- Fixes have tiers: `safe`, `likely`, `breaking` and `manual`. `corset fix` applies fixes up to the tier of the project.
- Output formats: text, JSON and SARIF 2.1.0.
- Corset checks scripts outside a project.
- Parse errors are findings. Rules still run on the rest of the file.
- The coverage line counts the places Corset could not analyze.

## 0.4.0

- Breaking: the rule `unwritten-undef` replaces `nan-initializer`. Rename `nan-initializer` in `[preferences.Corset.levels]`, `--allow`, `--warn`, `--deny` and `# lint:` comments. It also reports `similar(…)` and `T(undef, …)` arrays not provably written in full before any read.
