# Glossary

Terms this design coins.

| Term | Meaning |
|---|---|
| footgun | One problem Corset prevents. Source of truth; ID like F17. |
| check | Unit of config, opt-out and group. Covers one or more footguns. |
| kind | Variant inside check, with own message and fix. |
| layer | Data Corset computes, L1 syntax to L5 effects. |
| family | Analysis on layer output that checks share (A to H). |
| fact | Analysis output that checks read. |
| stand-in type | Type Corset defines to stand for whatever type caller passes, so inference sees concrete type. |
| generic argument | Annotation callers can fill with many types: `x::Real`, `x::T`. |
| overspecified type | Annotation that names specific number type, `AbstractFloat`, or concrete container anywhere inside. |
| escaping value | Value that leaves method: returned, or written to argument or global. |
| confidence | `definite`: problem exists. `possible`: perfect analysis would still be unsure. |
| blind spot | Site Corset cannot decide although perfect analysis could. Counted on coverage line; never finding. |
| level | `allow`, `warn` or `deny` per group or check. |
| fix tier | Risk of fix to callers: `safe`, `likely`, `breaking`, `manual`. |
| project kind | Preset of levels and tier: `library`, `application`, `script`. |
| baseline | Stored existing findings that never fail run. |
| opt-out | `# corset: allow <check> -- <reason>` comment. |
| coverage line | End-of-run count of blind spots by cause. |
