# Corset rewrite design

Read only parts task needs. Edit parts, then run `uv run docs/design/build.py`; it renders `rules-rewrite.html` and checks catalog invariants.
Never hand-edit `rules-rewrite.html`.

| File | Holds |
|---|---|
| `principles.md` | Principles, non-goals |
| `footguns.toml` | Footgun catalog: ID, text, example, group, stage, note. IDs stable; never reuse |
| `rules.toml` | Rules: name, footguns, note. Each footgun in exactly one rule; one group per rule |
| `stages.toml` | Analysis stages in pipeline order |
| `pipeline.md` | Stage order and diagram |
| `findings.md` | Groups, confidence, levels, opt-outs, config, project kind, fix tiers, messages, macro output, conventions |
| `types.md` | Stand-in types, type-disruption, lost narrowing, arguments without stand-in, annotations, union policy, Moshi, arrays |
| `effects.md` | `!` convention, name trust, effect facts |
| `engine.md` | Whole-program effects engine: points-to, calls, solve, library summary cache |
| `lifecycle.md` | Array allocations, events, paths and def-use facts; lifecycle rules |
| `architecture.md` | Code layout, core types, process model, tests, command line, rule contract, package load, cache, reference linters |
| `plan.md` | Phases, quality gate, speed budget |
| `phase5.md` | Phase 5 PR plan: `effects` and `lifecycle` stages and rules |
| `glossary.md` | Coined terms |
| `rules-rewrite-history.md` | Legacy rule names, early decisions, design review log. Add each review at end |
| `page.css` | Page style |

| Task | Read |
|---|---|
| Add or change rule | `footguns.toml`, `rules.toml`, `findings.md`, rule contract in `architecture.md` |
| Typed analysis | `types.md`, `pipeline.md` |
| `!` or effects | `effects.md` |
| Effects engine | `engine.md`, `effects.md` |
| Array def-use rules | `lifecycle.md`, `effects.md` |
| Engine, cache, CLI, tests | `architecture.md` |
| Pick next work | `plan.md`, `phase5.md` |
| Unknown term | `glossary.md` |
| Why legacy rule changed | `rules-rewrite-history.md` |
