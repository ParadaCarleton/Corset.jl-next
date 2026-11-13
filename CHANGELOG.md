# Changelog

## Unreleased

- Corset loads a package to check it. The `corset` command builds a temporary environment and runs again inside it.
- The temporary environment starts from the package Manifest and adds the test dependencies. A version change is a configuration error.
- A package that throws while loading gets a `load-error` finding. Rules that read the loaded package do not run.
- Corset loads the trigger packages of each extension, so rules see the extension. An extension that throws gets a `load-error` finding.
- New rule `shadowed-base`: a method named like an exported Base function defines a new function.
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
