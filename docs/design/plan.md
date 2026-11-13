# Build plan

Phases, spikes, quality gate and speed budget.

Draft. Spikes retire risks first. Each later phase ships usable rules. Phase order follows stage cost: syntax needs no package load, so it works on every project.

| Phase | Builds | Footguns | Exit |
|---|---|---|---|
| 0 spikes | S1 stand-in inference · S2 source mapping · S3 scope stage · S4 syntax matcher · S5 effect API. Measure legacy Corset on corpus as speed baseline. | — | Each spike works on Julia 1.13, or fallback is chosen. |
| 1 skeleton | Julia app `corset`; facts API and rule contract; config, project kind, groups, confidence, fix tiers; finding type with cause spans; message renderer; `corset explain`; opt-outs; baseline; text, JSON, SARIF output; fixer engine on lossless tree; UI snapshot tests and other harnesses. | — | One rule runs end to end: report, opt-out, baseline, fix, SARIF. Warm rerun inside speed budget. |
| 2 syntax | `syntax` stage. Copy ReLint.jl rules (Argus patterns) and LintApp.jl rules (in JuliaWorkspaces) where they exist. | {{count:syntax}} | Works on scripts. Reference comparison clean or allowlisted. **First release.** |
| 3 module | Package load in target environment; stages `package` and `external`. | {{count:package external}} | Load and rules run on every corpus package. |
| 4 types | Stand-in inference over every eligible package method (annotated, or reached from analyzed caller; coverage line counts the rest); `inference` stage and type-disruption scan; findings disk cache and per-method disk cache; `annotation` fixer guesses argument types and fills result types (annotation transition, `types.md`). | {{count:inference}} | Precision gate passes on corpus. `unverified-inbounds` agrees with julia-in-lean site verdicts. |
| 5 effects | `effects` stage: effect and alias summary; `lifecycle` stage reads callee writes from it; `!` convention flow. | {{count:effects lifecycle}} | Flow fixtures pass, IO, RNG and memo exemptions included. |
| 6 scope | `scope` stage on JuliaLowering (S3). | {{count:scope}} | Scope fixtures pass on packages and scripts. |
| later | F12, F45, F46, F49 (off by default); string and dict stand-in types; language server mode; Corset precompile workload (develop with Revise until then); test helper that runs rules on macro expansion, so macro authors check generated code (other packages' macro output gets no findings); replace `{}` stopgap with skip of macro arguments Julia rejects as written (`{x}`, `x ~ Normal()`), once `scope` lowering and `package` method tables can supply it; dimension-aware stand-in for `Number` (catches `x + 1` on Unitful quantity); nursery group for rules before quality gate; upstream F89 and F90 logic to Moshi `verify/` (owner approves PR); upstream root-kind rule index to Argus.jl (owner approves PR); prompt or LLM handoff for `manual` fixes; concrete probes for Base widening; warm daemon with incremental runs; borrow checking. | {{count:later}} | — |

### Spikes

- **S1 stand-in inference** (done, works with limits): every corpus method infers; 2 generated functions refused. Differential check right on 12 fixtures. Re-dispatch on real types separates stand-in blind spots. Found real bug (`DataStructures.empty(::DefaultDictBase)`).
- **S2 source mapping** (done, works with limits): 65% of findable statements map to exact bytes; about 2% of checked spans wrong. Code macros write maps to line only.
- **S3 scope stage** (done, works with limits): JuliaLowering at julia commit `f0188d597b` lowers every corpus form on 1.13. Exact bytes 83–99% with own Base-macro expansions. Warm 0.15 s per 10,000 lines; needs precompile workload in Corset. `Meta.lower` fallback dropped.
- **S4 syntax matcher** (done, `spikes/s4-syntax-matcher/REPORT.md`): Argus.jl 0.4.2 is MIT. Use Argus behind thin wrapper so matcher stays swappable. Argus searches whole tree once per rule (about 8× slower than kind-indexed walk); own walk with root-kind index should remove most of gap. Unmeasured: benchmark candidate-node design at planned rule count first in phase 2.
- **S5 effect summary** (done, works with limits): definite writes correct on corpus (splay trees, path compression, rotations). `possible` covers 75%, 55% and 52% of methods (Distances, DataStructures, JSON), all from unknown callees or unknown foreign calls. 17–22 s per package on quiet host. Internal API; pin per Julia minor version.

### Quality gate

Rule is on by default only when all hold:

- Fixture per footgun: positive, negative, and fix result.
- Any false `definite` finding blocks rule: it is rule bug. At least 90% of sampled `possible` findings are real problems.
- `definite` typed finding needs validated span: callee at mapped node matches IR callee; mismatch demotes span to line precision.
- Property tests (Supposition.jl) on programs built from UI case statements, with expressions spliced into value positions so fixes nest. Fixed code parses and lowers when original did. On code Julia accepts, fix removes its finding and adds none; `duplicate-statement` compares neighbors and is exempt. Fix runs converge. Equivalent `safe` fix keeps parsed meaning.
- Differential run: `safe` fix behaves same before and after on executed fixture. Not built yet.
- Message shows cause span and concrete fix; reviewed on corpus sample.
- Run time stays inside budget in CI perf test.

Speed budget (draft): time from Corset ready to findings out; Julia startup and target package load excluded. Full cold run at least 5× faster than legacy on same package; syntax-only run under 2 s per 10,000 lines; rerun with no changes under 1 s.

Legacy baseline (S4, warm, whole process): Distances 9.4 s, DataStructures 16–19 s, JSON 33–37 s. Remeasure legacy in same scope (startup and target load subtracted) before comparing. Main risks: stand-in inference, 7–17 s cold per package (S1); effect summary, 17–22 s uncached (S5). Corset precompile workload, Base summary cache and per-method disk cache must close gap; effects phase gets own budget once Base cache exists.

Repository bar: 100% line coverage; mutation testing on rule code. Corpus: packages that already run legacy Corset, plus three registered packages of different style (numeric, data, IO).

### Design reviews

Design is draft until code proves it. Revisit at each checkpoint:

- After phase 0: spike results confirm or replace stand-in inference, scope stage, syntax matcher and effect summary. Rewrite affected parts before phase 1.
- After first release: corpus findings and real use test footgun list, levels, presets and messages.
- After phase 4: measure annotation transition guesses on corpus (share kept after review); revise evidence ranking, widening and tiers (`types.md`). Replace indexing exemption of `type-disruption` with exact conversion rule.
- Before each later phase: reread parts that phase builds on; question decisions that no longer fit.
- Before phase 5: decide whether `lifecycle` def-use runs on syntax tree or reuses `effects` points-to graph over IR (one producer per fact).
- Each review: adversarial pass by second model on changed parts; log findings and outcomes in `rules-rewrite-history.md`.
- Change decision openly: edit part, note reason in commit message. Footgun IDs stay stable through every change.
