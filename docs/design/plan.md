# Build plan

Phases, quality gate and speed budget. Phase 5 PR plan: `phase5.md`.

Draft. Each phase ships usable rules. Phase order follows stage cost: syntax needs no package load, so it works on every project.

| Phase | Builds | Footguns | Exit |
|---|---|---|---|
| 1 skeleton | Julia app `corset`; facts API and rule contract; config, project kind, groups, confidence, fix tiers; finding type with cause spans; message renderer; `corset explain`; opt-outs; baseline; text, JSON, SARIF output; fixer engine on lossless tree; UI snapshot tests and other harnesses. | — | One rule runs end to end: report, opt-out, baseline, fix, SARIF. Warm rerun inside speed budget. |
| 2 syntax | `syntax` stage. Copy ReLint.jl rules (Argus patterns) and LintApp.jl rules (in JuliaWorkspaces) where they exist. Parse errors as findings; file role fact; reference comparison harness with allowlist. | {{count:syntax}} | Works on scripts. Reference comparison clean or allowlisted. **First release.** |
| 3 module | Package load: command line builds temporary environment and relaunches (architecture.md, "Process model"). Extension triggers loaded. Load errors as findings. Stages `package` and `external`. | {{count:package external}} | Load and rules run on every corpus package. |
| 4 types | Stand-in inference over every eligible package method (annotated, or reached from analyzed caller; coverage line counts the rest); `inference` stage and type-disruption scan; findings disk cache; `annotation` fixer guesses argument types and fills result types (annotation transition, `types.md`). | {{count:inference}} | Precision gate passes on corpus. `unverified-inbounds` agrees with julia-in-lean site verdicts. |
| 5 effects | `effects` stage on name trust: `!` names, builtin stores, closures and compiler effects per method (`effects.md`); `lifecycle` stage reads its events; `!` convention flow. | {{count:effects lifecycle}} | Name-tier fixtures pass, IO, RNG and memo exemptions included. Each rule passes quality gate on corpus. |
| 6 scope | `scope` stage on JuliaLowering. | {{count:scope}} | Scope fixtures pass on packages and scripts. |
| later | F12, F45, F46, F49, F76 (off by default); string and dict stand-in types; language server mode; directory discovery reads `.gitignore` and `.ignore`, like Ruff; test helper that runs rules on macro expansion, so macro authors check generated code (other packages' macro output gets no findings); replace `{}` stopgap with skip of macro arguments Julia rejects as written (`{x}`, `x ~ Normal()`), once `scope` lowering and `package` method tables can supply it; dimension-aware stand-in for `Number` (catches `x + 1` on Unitful quantity); nursery group for rules before quality gate; upstream to Moshi in order (owner approves each PR): unreachable-arm check (Roger-luo/Moshi.jl#96), exhaustiveness check, order chains (fork branch `data-order`, PR after #96 gets review); after Moshi release, `unchecked-enum` moves Corset enums to Moshi; upstream root-kind rule index to Argus.jl (owner approves PR); prompt or LLM handoff for `manual` fixes; concrete probes for Base widening; warm daemon with incremental runs; secret scan that finds hard-coded tokens and keys in string literals and tracked files, with gitleaks rule set; shape and axis checking: track array sizes and axes through code, so dimension mismatch (`A * B`, broadcast, `dims` argument) and axes of one array used to index other array give findings; borrow checking. | {{count:later}} | — |

### Quality gate

Rule is on by default only when all hold:

- Fixture per footgun: positive, negative, and fix result.
- Any false `definite` finding blocks rule: it is rule bug. At least 90% of sampled `possible` findings are real problems.
- `definite` typed finding needs validated span: callee and argument count at mapped node match IR call, and calls of one callee in one statement map in source order. Mismatch demotes span to line precision. Generated function output, macro output and compiler-made statements (`kwcall` wrappers) stay at line precision.
- Property tests (Supposition.jl) on programs built from UI case statements, with expressions spliced into value positions so fixes nest. Fixed code parses and lowers when original did. On code Julia accepts, fix removes its finding and adds none; `duplicate-statement` compares neighbors and is exempt. Fix runs converge. Equivalent `safe` fix keeps parsed meaning.
- Differential run: `safe` fix behaves same before and after on executed fixture. Not built yet.
- Message shows cause span and concrete fix; reviewed on corpus sample.
- Run time stays inside budget in CI perf test. Same test checks each rule, parse and whole run for cost linear in function size.

Speed budget (draft): time from Corset ready to findings out; Julia startup and target package load excluded. Syntax-only run under 2 s per 10,000 lines; rerun with no changes under 1 s.

- `check` and `inference` stages: full cold run at least 5× faster than legacy on same package.
- `effects` stage has no run-time budget (`engine.md`, Solve and cache). Phase 5 row 5 measures its time against `inference` stage.
- Legacy runs no effects analysis, so ratio to legacy leaves `effects` stage out.

Syntax stage: 21 rules take 15–40 ms per 10,000 lines; rule time grows linearly with rule count.

Cold run, same scope (target loaded first, default threads):

| Package | Legacy | Corset (`check` + `inference` stage) | Ratio | 5× budget |
|---|---|---|---|---|
| Distances 0.10.12 | 12.0–12.8 s | 3.5 s | 3.5× | 2.5 s |
| DataStructures 0.18.22 | 19.8–20.6 s | 6.8–7.1 s | 2.9× | 4.0 s |

`benchmark/cold.jl` measures Corset. Cold run misses budget on Distances and DataStructures.
Nearly all of `inference` stage is Julia inference of target methods at declared or stand-in signatures; Corset machinery and Base callees on stand-ins add about 0.1 s. Package image holds neither Corset's signatures nor target's: target's own precompile workload caches concrete calls only (JSON ships one). So method store keeps facts per method: later runs infer only methods that edit touched.
Rerun with no changes, same scope: about 0.5 s on DataStructures, from cache. Whole process takes 2.2–2.6 s; loading Corset takes 1.3 s of it.

Rerun after edit of one file: `inference` stage with method store, seconds; store key and shape add 0.1–0.3 s.

| Package | Cold | Unchanged | Edited file | After edit |
|---|---|---|---|---|
| DataStructures | 3.0 | 0.21 | `heaps/binary_heap.jl` | 0.26 |
| Distances | 3.2 | 1.1 | `haversine.jl` | 1.1 |
| JSON | 3.3 | 0.28 | `lazy.jl` | 0.94 |

Distances loads ChainRulesCore.jl, whose `promote_rule` invalidates JuliaSyntax.jl line lookup; stage recompiles about 1 s of Corset code.

Repository bar: 100% line coverage; mutation testing on rule code. Corpus: packages that already run legacy Corset, plus registered packages Distances, SpecialFunctions, StatsFuns, Distributions (numeric) and DataStructures (data).

### Design reviews

Design is draft until code proves it. Revisit at each checkpoint:

- After first release: corpus findings and real use test footgun list, levels, presets and messages.
- After phase 4: measure annotation transition guesses on corpus (share kept after review); revise evidence ranking, widening and tiers (`types.md`). Revisit integer input of `type-disruption` if corpus shows integer widening outside index math.
- Before each later phase: reread parts that phase builds on; question decisions that no longer fit.
- After phase 5 rule rows: compare engine verdicts with name trust on corpus before engine verdicts feed facts.
- Each review: adversarial pass by second model on changed parts; log findings and outcomes in `rules-rewrite-history.md`.
- Change decision openly: edit part, note reason in commit message. Footgun IDs stay stable through every change.
