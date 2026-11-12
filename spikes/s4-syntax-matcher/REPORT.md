# S4 syntax matcher: report

Verdict: works. Own matcher on JuliaSyntax green trees runs on Julia 1.13.3, 70–100× under syntax budget.
Argus.jl is no longer blocked: registered Argus 0.4.2 ships MIT `LICENSE.md` (Copyright 2025-2026 Iulia Dumitru). Owner: confirm and update plan.

## Matcher

- `src/S4Matcher.jl`: about 300 lines. Pattern is Julia source with holes, compiled once by JuliaSyntax.
- Holes: `_x` binds one node, `_` matches any node, `_xs...` binds zero or more siblings (backtracking).
- Repeated named hole requires structurally equal subtree (`f(_x, _x)`).
- Target is green tree plus byte offset ("red" node built on the fly); trivia skipped; leaves compared by bytes, no allocation.
- Normalization: redundant parentheses dropped; infix call `a ≈ b` matches prefix `≈(a, b)`.
- Guards: Julia function `(bindings, node, ancestors) -> Bool`. `contains_match` searches subtree with pre-bound holes.
- One walk per file; rules indexed by pattern root kind; walk keeps ancestor stack.
- Ideas taken: `SyntaxCheck` kind index (JuliaWorkspaces `lint_syntax_rules/engine.jl`, MIT); hole syntax and `~inside` need (Argus, via ReLint). No code copied.
- `src/rules.jl`: F10 `approx-zero`, F21 `empty-any-literal`, F35 `fill-shared-mutable`, F36 `one-to-length`, F68 `threadid-buffer`. Extra LintApp-shaped F36 rule: `for i in 1:length(a)` or generator whose body indexes `a[i]`.
- F36 guard skips function that calls `require_one_based_indexing` on same array (needs ancestors).
- `test/runtests.jl`: 35 positive, negative and matcher cases pass.

## Measurements

Host: Julia 1.13.3, JULIA_NUM_THREADS=2, 14 GB host shared with other agents. Times are minimum of 20 runs after warmup unless noted.

Corpus (src/ and ext/; tests never read): Distances 0.10.12 (2,090 lines), DataStructures 0.19.6 (11,472), JSON 1.13.4 (4,448).

| Package | Parse | Match (6 rules) | Per 10k lines | Findings |
|---|---|---|---|---|
| Distances | 2.6 ms | 2.9 ms | 27 ms | 0 |
| DataStructures | 12.4 ms | 9.9 ms | 19 ms | 11 |
| JSON | 6.2 ms | 6.1 ms | 28 ms | 4 |

Command: `julia --project=spikes/s4-syntax-matcher spikes/s4-syntax-matcher/bench/corpus.jl out.json`.

- Stress: newest src/ of all 695 packages in local depot, 9,582 files, 2.24 M lines: parse 3.5 s, match 3.5 s, 31 ms per 10k lines, 0 crashes (`bench/stress.jl`).
- Rule scaling (`bench/scaling.jl`, rules sharing root kind `call`): 5 rules 10 ms, 20 rules 39 ms, 50 rules 105 ms, 100 rules 208 ms per 10k lines. Cost is linear in rules per root kind. Index by callee name removes most of it; not built.
- One-shot process wall (startup, JIT, one pass): 1.4–2.0 s, 306–378 MB RSS with registered JuliaSyntax 1.0.2. With `Base.JuliaSyntax` (shipped in Julia 1.13): 1.2–1.3 s, 296 MB, same findings. Plain `julia -e 0`: 0.11 s, 164 MB. Remaining cost is JIT; precompile workload should remove it.
- Argus 0.4.2 with same five footguns (`refs/relint/argus5.jl`): 186–230 ms per 10k lines, about 8× slower than own matcher, inside budget.
- ReLint 0.9.0 (commit 6107942, about 40 Argus rules, `refs/relint/run.jl`): 1.16–1.68 s per 10k lines warm. Argus cost grows with rule count; 50+ checks would exceed 2 s budget.
- LintApp 1.0.2 (`julialint`) process wall: Distances 6.1 s / 881 MB, DataStructures 5.4 s / 630 MB, JSON 21.7 s / 943 MB.

## Legacy Corset speed baseline

Legacy `corset check` from main (bbfb145), workspace Manifest resolved 2026-11-11. Each run is fresh process; Corset already precompiled (precompile alone: 38 s).
Cold is first run after corpus instantiate and precompile; warm is runs 2 and 3. Peak RSS is maximum over process tree.

| Package | Cold | Warm | Peak RSS | `--no-load` wall | `--no-load` RSS |
|---|---|---|---|---|---|
| Distances | 9.6 s | 9.3–9.4 s | 659 MB | 2.8–2.9 s | 476 MB |
| DataStructures | 16.8 s | 16.1–18.7 s | 796 MB | 3.2 s | 503 MB |
| JSON | 36.6 s | 33.3–33.9 s | 1158 MB | 3.0 s | 480 MB |

Command: `python3 -I bench/legacy.py <corset-checkout> 3 - <package-dir>`; syntax-only: replace `-` with `--no-load`.
Cold barely differs from warm: package load and inference dominate; compile caches do not.
Budget "5× faster than legacy" (plan.md:36) means full cold run under 1.9 s, 3.4 s and 6.7 s.

## Reference comparison

Findings for overlapping footguns on corpus (`bench/corpus-findings.json`). Broad and loop F36 rules report same sites twice by design of this spike.

| Footgun | Own matcher | Argus, same patterns | LintApp `index_from_length` | ReLint |
|---|---|---|---|---|
| F36 broad `1:length(a)` | 7 | 9 | — | — |
| F36 loop or generator indexes `a` | 7 | — | 2 | — |
| F21 `[]` and friends | 1 | 1 | — | 0 (rule limited to `src/Compiler`) |
| F10, F35, F68 | 0 | 0 | — | — |

- Own vs Argus: identical except Distances `generic.jl:209,211`; own guard sees `require_one_based_indexing(r, a, b)` and skips.
- LintApp finds JSON `write.jl:1014` and `JSONArrowExt.jl:25`; own matcher finds both.
- LintApp misses DataStructures `minmax_heap.jl:145` (`A::AbstractVector`, real F36), `circ_deque.jl:124` and three `sorted_*.jl` generators over `x.vec[i]`. LintApp exempts arrays it types as vectors.
- `circ_deque.jl:124` indexes `CircularDeque`, which defines 1-based `getindex`; syntax cannot know. F36 at syntax layer is `possible` only.
- Stress precision sample (all hits in 695 packages): F10 15/15 real `x ≈ 0`; F68 4/4 real; F35 6/6 share one mutable object, but harm needs later mutation (family B).

## Gaps

- Index by callee name not built; needed before about 50 call-rooted checks.
- Guards are free Julia functions; no declarative `~inside` or `~or`. Ancestor stack covers `~inside`.
- No macro expansion: patterns inside macro calls match only literal source.
- Dotted calls (`.≈`), chained comparisons and multi-iteration `for i = …, j = …` not normalized.
- Comments and whitespace invisible to patterns. F1 `[1 -2]` needs trivia; tree keeps it, matcher ignores it.
- Matcher not precompiled; one-shot wall is JIT.

## Design parts contradicted

- plan.md:23 and families.toml:8: Argus license block is stale. Argus 0.4.2 is MIT. Choice now rests on speed and API.
- plan.md:11 "copy matchers from ReLint": ReLint rules are Argus patterns. Copy means Argus dependency or rewrite into own syntax.
- architecture.md:102 lists LintApp as MIT check code source: its checks live in JuliaWorkspaces (vendored StaticLint, CSTParser).
- pipeline.md:8 "milliseconds" per file: confirmed (20–30 ms per 10k lines).
- plan.md:36 cold run 5× faster than legacy: legacy `--no-load` already spends 2.8–3.2 s on startup. Distances target of 1.9 s leaves almost nothing for package load and inference.
- ReLint Project.toml reuses StaticLint UUID `b3cc710f-…`; reference test env must keep ReLint and LintApp apart.

## Reproduce

- Spike env: `julia --project=spikes/s4-syntax-matcher -e 'using Pkg; Pkg.instantiate()'`, then `test/runtests.jl` and `bench/*.jl`.
- ReLint env: `refs/relint/Project.toml` (ReLint from GitHub URL source). LintApp env: `refs/lintapp/Project.toml`.
- LintApp: `julia --project=refs/lintapp -e 'using LintApp; exit(LintApp.main(ARGS))' -- --format json --no-progress -o out.json <package-dir>`.
- Corpus copies (src, ext, Project.toml only) lived in `.worktrees/s4-corpus`; legacy needs instantiated writable project.
- Wall and RSS helper: `python3 -I bench/wall.py <command>`.
