# CLI

```bash
corset <command> [path] [options]
```

`path` is a file or a directory. The default is `.`. Corset finds the project at or above `path`.

Some rules read the loaded package. For these rules, `corset` builds a temporary environment and runs again inside it.
The guide section "Load errors" describes this environment.

## Commands

| Command | Action |
| --- | --- |
| `check` | Report findings. |
| `fix` | Apply fixes up to the fix tier, then report the findings that remain. |
| `baseline` | Write the current findings to `corset-baseline.toml`. |
| `explain <rule>` | Print the documentation of a rule. |

`explain` also knows the checks that are always on: `opt-out`, `parse-error`, `load-error` and `baseline`.

## Options

`check`, `fix` and `baseline` take these options:

| Option | Values | Default |
| --- | --- | --- |
| `--format` | `text`, `json`, `sarif` | `text` |
| `--confidence` | `definite`, `possible` | from the configuration |
| `--no-cache` | (flag) | cache on |

`fix` also takes `--tier` with `safe`, `likely` or `breaking`. The default comes from the configuration.

## Cache

Corset stores the analysis of each checked path in its scratch space in the Julia depot.
A later run with the same inputs prints the stored findings. It loads no package and starts no second Julia process.
The inputs are:

- the Julia version and its cache flags, such as `--check-bounds`
- the Corset source
- the options and level flags
- the environment, with its Manifest and preferences
- every file of the project and of its path dependencies

Hidden files and directories do not count. Coverage files (`.cov`, `.mem`) do not count.
The first run on a path prints a note. `--no-cache` analyzes again and reads or writes no cache.
CI that saves the Julia depot between runs keeps the cache.

## Level flags

Level flags work as in rustc. Each flag takes a group or a rule name:

| Flag | Level |
| --- | --- |
| `-A`, `--allow` | `allow` |
| `-W`, `--warn` | `warn` |
| `-D`, `--deny` | `deny` |

Corset applies the flags in order, after the configuration. `-D warnings` makes warnings fail the run.

```bash
corset check src -A readability -W nan-compare -D warnings
```

## Output formats

- `text`: one block per finding, then a summary line and the [coverage line](guide.md#Coverage-line).
- `json`: Corset JSON, with a `version` key.
- `sarif`: SARIF 2.1.0, for code-scanning tools.

Columns count code points. Byte offsets are exact.

## Exit codes

Exit codes follow Cargo:

| Code | Meaning |
| --- | --- |
| `0` | No finding fails the run. |
| `1` | At least one finding fails the run. |
| `2` | The command line or the configuration has an error. |
| `101` | Corset has an internal error. |
