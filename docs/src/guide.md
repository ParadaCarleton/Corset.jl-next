# Guide

## Project kind

The project kind tells who uses the code. The kind picks the groups Corset reports and the highest fix tier `corset fix` applies.

| Kind | Groups | Fix tier |
| --- | --- | --- |
| `library` | `correctness`, `performance`, `composability`, `readability` | `likely` |
| `application` | `correctness`, `performance`, `readability` | `breaking` |
| `script` | `correctness`, `readability` | `breaking` |

Findings in the `correctness` group have level `deny`. Findings in the other groups of the kind have level `warn`.
Groups outside the kind have level `allow`.

Corset finds the kind as follows:

- A file outside a project is a `script`.
- A project without a `name` in `Project.toml` is an `application`.
- A package must set `kind` in its configuration. Without it, Corset stops with a configuration error.

## Levels

Each finding has one of three levels, as in Clippy:

- `deny`: the finding fails the run.
- `warn`: the finding shows, but the run passes. `-D warnings` makes warnings fail the run.
- `allow`: Corset does not report the finding.

Set a level for a group or for one rule. A rule level overrides its group level.
The command line overrides the configuration.

## Configuration

Write the configuration in `Project.toml`:

```toml
[preferences.Corset]
kind = "library"
confidence = "definite"
fix_tier = "likely"

[preferences.Corset.levels]
readability = "allow"
nan-compare = "warn"

[[preferences.Corset.banned]]
pattern = "@show({_}...)"
reason = "debug print; use `@debug`"

[[preferences.Corset.banned]]
name = "tmp.*"
reason = "name what the value holds"
```

| Key | Values | Default |
| --- | --- | --- |
| `kind` | `library`, `application`, `script` | see [Project kind](#Project-kind) |
| `confidence` | `definite`, `possible` | `definite` |
| `fix_tier` | `safe`, `likely`, `breaking` | from the kind |
| `levels` | group or rule name to `allow`, `warn`, `deny` | from the kind |
| `banned` | list of tables with `pattern` or `name`, and `reason` | no bans |

A `[Corset]` table in `LocalPreferences.toml` overrides the same keys for one machine.
`levels` merge name by name. A `banned` list replaces the full list.

Each `banned` entry has exactly one of two keys:

- `pattern`: an [Argus](https://github.com/iuliadmtru/Argus.jl) syntax pattern.
- `name`: a regular expression that must match the full bound name.

The [`banned`](rules.md#banned) rule reports each match with its reason.

## Opt-out comments

An opt-out comment stops findings of the rules it names:

```julia
@test !(x == NaN) # corset: allow nan-compare -- test checks the IEEE result

# corset: allow broad-catch -- worker logs each error and continues
try
    run_job(job)
catch
    @error "job failed" job
end
```

- A comment after code covers its line.
- A comment on its own line covers the next statement: a function, struct, block or expression.
- `# corset: allow-file <rule> -- <reason>` before the first code covers the file.

Each opt-out needs a reason after `--`. Corset reports these problems, and each one fails the run:

- a malformed comment
- a missing reason
- an unknown rule
- an `allow-file` comment after code
- an opt-out that stops no finding

## Baseline

A baseline lets you adopt Corset on code that has findings. It records the current findings. Corset counts them as baselined, and they do not fail the run.

```bash
corset baseline
```

The command writes `corset-baseline.toml` at the project root. Commit the file.
New findings fail the run as usual.

A baseline entry has no line number. It records the rule, the file, the enclosing definition and a hash of the code.
Edits in other parts of the file keep the entry valid.
An entry that matches no finding is stale and fails the run. Run `corset baseline` again to remove it.

## Fixes

Each fix has a tier:

| Tier | Meaning |
| --- | --- |
| `safe` | keeps behavior, or fixes a definite bug inside one method |
| `likely` | can change what callers see, such as a result type |
| `breaking` | changes the public API |
| `manual` | needs a human choice; Corset shows the fix and never applies it |

`corset fix` applies each fix up to the fix tier, then reports the findings that remain.
When two fixes change the same code, Corset applies the first. Run `corset fix` again to apply the next.

## Confidence

A `definite` finding is a problem for each input. A `possible` finding depends on facts that the code does not settle.
Corset reports `definite` findings only. Set `confidence = "possible"` to see both.

## Coverage line

The last line of the text report counts the files Corset analyzed.
It also counts each place that Corset could not analyze, by cause:

```text
coverage: analyzed 12 files; skipped 1 (include with computed path)
  - src/Plugins.jl:4:1: include with computed path
```

A skipped place is a blind spot. Corset can miss findings there.

## Parse errors

Corset reports code that JuliaSyntax cannot parse as a `parse-error` finding. Rules still run on the rest of the file.
No level, opt-out or baseline hides a parse error.

## Load errors

Some rules read the loaded package. For these rules, the `corset` command builds a temporary environment and runs again inside it.
The environment starts from the package Manifest, develops the package by path and adds its test dependencies.
Every Manifest version stays; a resolution that needs another version is a configuration error.
Julia in the environment loads only from that environment and the standard library.
The first run builds the environment. Later runs reuse it until the project files or the Julia version change.
`Corset.check` in Julia code does not relaunch: the active environment must load the package from its root.

A package that throws while loading gets a `load-error` finding at the line that threw.
Rules that read the loaded package do not run, and the coverage line says so.
Corset loads the trigger packages of each extension, and the extension loads with them.
Test dependencies supply the triggers. An extension without an installed trigger is a blind spot.
An extension that throws gets a `load-error` finding; rules still read the package.
No level, opt-out or baseline hides a load error.
