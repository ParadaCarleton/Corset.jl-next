# Corset rewrite design

Read only parts task needs. Edit parts, then run `uv run docs/design/build.py`; it renders `rules-rewrite.html` and checks catalog invariants.
Never hand-edit `rules-rewrite.html`.

| File | Holds |
|---|---|
| `principles.md` | Principles, non-goals |
| `footguns.toml` | Footgun catalog: ID, text, example, group, family, note. IDs stable; never reuse |
| `rules.toml` | Rules: name, footguns, note. Each footgun in exactly one rule; one group per rule |
| `families.toml` | Analysis families A to H |
| `pipeline.md` | Layers L1 to L5 and diagram |
| `findings.md` | Groups, confidence, levels, opt-outs, config, project kind, fix tiers, messages, macro output, conventions |
| `types.md` | Stand-in types, type-disruption, arguments without stand-in, annotations, union policy, Moshi, arrays |
| `effects.md` | `!` convention, effect summary |
| `architecture.md` | Code layout, core types, process model, tests, command line, rule contract, package load, cache, reference linters |
| `plan.md` | Phases, spikes, quality gate, speed budget |
| `glossary.md` | Coined terms |
| `rules-rewrite-history.md` | Legacy rule names, early decisions, review log. Frozen |
| `page.css` | Page style |

| Task | Read |
|---|---|
| Add or change rule | `footguns.toml`, `rules.toml`, `findings.md`, rule contract in `architecture.md` |
| Typed analysis | `types.md`, `pipeline.md` |
| `!` or effects | `effects.md` |
| Engine, cache, CLI, tests | `architecture.md` |
| Pick next work | `plan.md` |
| Unknown term | `glossary.md` |
| Why legacy rule changed | `rules-rewrite-history.md` |
