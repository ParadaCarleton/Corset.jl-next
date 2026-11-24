# Glossary

Terms this design coins.

| Term | Meaning |
|---|---|
| footgun | One problem Corset prevents. Source of truth; ID like F17. |
| rule | Pure function from facts to findings. Unit of config, opt-out and level. Covers one or more footguns. Argus.jl `Rule` is different; Corset uses only Argus patterns. |
| kind | Variant inside rule, with own message and fix. |
| stage | Analysis step that computes facts once per run: `syntax`, `package`, `scope`, `inference`, `effects`, `lifecycle`, `external`. Rule belongs to last stage it reads. |
| fact | Analysis output that rules read. |
| allocation | Statement that gives new `Array`, `BitArray` or array stand-in by Base table (`lifecycle.md`). Package call result is none. |
| fill loop | Loop over all indices of array that writes element at iteration index on every iteration. Counts as whole write. |
| rebind pair | Loop `φ` that joins array before loop with array that loop body allocates (F41). |
| stand-in type | Type Corset defines to stand for whatever type caller passes, so inference sees concrete type. |
| generic argument | Annotation callers can fill with many types: `x::Real`, `x::T`. |
| overspecified type | Annotation that names specific number type, `AbstractFloat`, or concrete container anywhere inside. |
| escaping value | Value that leaves method: returned, or written to argument or global. |
| confidence | `definite`: problem exists. `possible`: compiler cannot resolve doubt either. |
| blind spot | Doubt compiler resolves but Corset cannot. Counted on coverage line; never finding. |
| level | `allow`, `warn` or `deny` per group or rule. |
| diagnostic | Finding with level applied; what Corset reports. |
| fix tier | Risk of fix to callers: `safe`, `likely`, `breaking`, `manual`. |
| project kind | Preset of levels and tier: `library`, `application`, `script`. |
| baseline | Stored existing findings that never fail run. |
| opt-out | `# corset: allow <rule> -- <reason>` comment. |
| coverage line | End-of-run count of blind spots by cause. |
| name trust | `effects` stage assumption: function writes an argument only when its name ends in `!`. Callee name stands in for callee body. |
| order chain | Moshi `@data` body `A() < B() < C()`: declares singleton variants and their order. |
