# CLI

```bash
corset <command> [path] [options]
```

`path` is a file or a directory. The default is `.`. Corset finds the project at or above `path`.

## Commands

| Command | Action |
| --- | --- |
| `check` | Report findings. |
| `fix` | Apply fixes up to the fix tier, then report the findings that remain. |
| `baseline` | Write the current findings to `corset-baseline.toml`. |
| `explain <rule>` | Print the documentation of a rule. |

`explain` also knows the checks that are always on: `opt-out`, `parse-error` and `baseline`.

## Options

`check`, `fix` and `baseline` take these options:

| Option | Values | Default |
| --- | --- | --- |
| `--format` | `text`, `json`, `sarif` | `text` |
| `--confidence` | `definite`, `possible` | from the configuration |

`fix` also takes `--tier` with `safe`, `likely` or `breaking`. The default comes from the configuration.

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
