# Build plan

Phases, spikes, quality gate and speed budget.

Draft. Spikes retire risks first. Each later phase ships usable checks. Phase order follows layer cost: syntax needs no package load, so it works on every project.

| Phase | Builds | Footguns | Exit |
|---|---|---|---|
| 0 spikes | S1 stand-in inference · S2 source mapping · S3 scope layer · S4 syntax matcher · S5 effect API. Measure legacy Corset on corpus as speed baseline. | — | Each spike works on Julia 1.13, or fallback is chosen. |
| 1 skeleton | Julia app `corset`; facts API and check contract; config, project kind, groups, confidence, fix tiers; finding type with cause spans; message renderer; `corset explain`; opt-outs; baseline; text, JSON, SARIF output; disk cache for syntax findings; fixer engine on lossless tree; UI snapshot tests and other harnesses. | — | One check runs end to end: report, opt-out, baseline, fix, SARIF, cached rerun. |
| 2 syntax | Families A and B. Copy matchers from LintApp.jl and ReLint.jl where they exist. | {{count:A B}} | Works on scripts. Reference comparison clean or allowlisted. **First release.** |
| 3 module | Package load in target environment; families C and G. | {{count:C G}} | Load and checks run on every corpus package. |
| 4 types | Stand-in inference over every package method; family D and type-disruption scan; per-method disk cache; `annotation` fixer fills result types from inference. | {{count:D}} | Precision gate passes on corpus. `unverified-inbounds` agrees with julia-in-lean site verdicts. |
| 5 effects | Effect and alias summary; family E; `!` convention flow. | {{count:E}} | Flow fixtures pass, IO, RNG and memo exemptions included. |
| 6 scope | Family H on scope layer chosen in S3. | {{count:H}} | Scope fixtures pass on packages and scripts. |
| later | F12, F45, F46, F49 (off by default); compiled-instance specialization count; string and dict stand-in types; language server mode; dimension-aware stand-in for `Number` (catches `x + 1` on Unitful quantity); nursery group for checks before quality gate; upstream F89 and F90 logic to Moshi `verify/` (owner approves PR); prompt or LLM handoff for `manual` fixes; concrete probes for Base widening; warm daemon with incremental runs; borrow checking. | {{count:later}} | — |

### Spikes

- **S1 stand-in inference**: float, integer, array and function stand-in types; per-subtype inference for package abstract types; infer every method of three corpus packages. Measure stand-in gaps, run time and count of integer-literal findings. `never-succeeds` must ignore calls that fail only because stand-in type lacks method.
- **S2 source mapping**: TypedSyntax.jl maps typed findings to bytes, macro output included.
- **S3 scope layer**: JuliaLowering does not ship with Julia 1.13 and is not registered; it lives in JuliaLang/julia as `1.0.0-DEV`. Try it from source. Fallback: `Meta.lower` per top-level form, with line positions only.
- **S4 syntax matcher**: Argus.jl shows no license. Ask author, or use own matcher on JuliaSyntax. Compare with LintApp.jl and ReLint.jl code (MIT).
- **S5 effect summary**: Julia reports no per-argument writes, so build own summary bottom-up over call graph: escape analysis inside method, callee summaries at calls. Unknown callee gives `possible`. Internal API; pin per Julia minor version.

### Quality gate

Check is on by default only when all hold:

- Fixture per footgun: positive, negative, and fix result.
- Any false `definite` finding blocks check: it is check bug. At least 90% of sampled `possible` findings are real problems.
- Property tests (Supposition.jl): fix creates no new finding; fix is idempotent. `safe` fix: fixture behaves same before and after (differential run).
- Message shows cause span and concrete fix; reviewed on corpus sample.
- Run time stays inside budget in CI perf test.

Speed budget (draft): full cold run at least 5× faster than legacy on same package; syntax-only run under 2 s per 10,000 lines after startup; rerun with no changes under 1 s.

Repository bar: 100% line coverage; mutation testing on check code. Corpus: packages that already run legacy Corset, plus three registered packages of different style (numeric, data, IO).
