# S2 source mapping: report

Verdict: **works with limits**. Use TypedSyntax.jl mapping algorithm (`map_ssas_to_source`) for byte spans. Do not use its CodeTracking front end. Vendor and adapt algorithm (MIT, about 450 lines) onto own file parse. Use debuginfo line as fallback.

Julia 1.13.3, TypedSyntax 1.5.4, JuliaSyntax 1.0.2. Corpus: Distances 0.10.12, DataStructures 0.19.6, JSON 1.13.4 (2285 methods, 53,980 statements of unoptimized typed IR).

## Reproduce

```
cd spikes/s2-source-mapping
julia --project=. -e 'using Pkg; Pkg.instantiate()'
for mode in codetracking file file_lambda
    S2_ROOT=$mode JULIA_NUM_THREADS=2 julia --startup-file=no --project=. measure.jl
    uv run --with polars summarize.py $mode > out/$mode/summary.txt
end
S2_ROOT=file julia --startup-file=no --project=. render.jl
```

Modes:
- `codetracking`: TypedSyntax default. `CodeTracking.definition` gives method text; TypedSyntax parses it.
- `file`: parse whole file once; find definition node at `Method.line`; give node to `map_ssas_to_source`. Byte ranges are file offsets; no correction.
- `file_lambda`: `file` plus 4-line patch so TypedSyntax accepts `->` and `do` roots (top of `measure.jl`).

Each method uses existing compiled specialization, else declared signature. Output: `out/<mode>/summary.txt` (tables), `out/<mode>/cases.txt` (per-statement dump of `cases.jl`).

## Classes

- `exact`: one syntax node; byte span checked against file bytes.
- `ambiguous`: several candidate nodes on statement line.
- `line_only`: no node; debuginfo line lies inside method definition.
- `foreign_line`: debuginfo line lies outside definition (macro body, `@eval` template).
- `missing`: no line (line 0 or file `none`).

Findable statements: calls, `new`, broadcast, `kwcall`. Findings point at these.

## Measurements

Share of statements, `file_lambda`:

| Scope | n | exact | ambiguous | line_only | foreign_line | missing |
|---|---|---|---|---|---|---|
| all | 53,980 | 0.459 | 0.072 | 0.303 | 0.067 | 0.099 |
| findable | 17,915 | 0.654 | 0.051 | 0.227 | 0.044 | 0.024 |

Findable exact share by mode: `codetracking` 0.640, `file` 0.647, `file_lambda` 0.654.

Findable, by method kind (`file_lambda`):

| Method kind | n | exact | line_only | missing |
|---|---|---|---|---|
| plain | 16,716 | 0.672 | 0.210 | 0.019 |
| keyword body (`#f#3`) | 508 | 0.638 | 0.254 | 0.079 |
| closure, do-block | 273 | 0.451 (0.0 in `codetracking`) | 0.271 | 0.249 |
| `kwcall` wrapper | 239 | 0.184 | 0.728 | 0.0 |
| macro-defined (`@kwdef`, `@deprecate`) | 179 | 0.0 | 1.0 | 0.0 |

Findable exact share by enclosing macro: `@inline` 0.82, `@inbounds` 0.78, `@simd` 0.91, `@views` 0.78, `GC.@preserve` 0.78, `@propagate_inbounds` 0.83, `@assert` 0.51, `@eval` 0.34 (0.41 foreign_line), `@kwdef` 0.0, `@deprecate` 0.0, `@enum` 0.0.

Per case (`out/file_lambda/cases.txt`):

| Case | Result |
|---|---|
| plain call | exact: `abs(x)`, `sqrt(abs(x))`, `sqrt(abs(x)) + 1` |
| broadcast | exact on `materialize` (whole fused expression) and outer `broadcasted`; inner nested `broadcasted` line only |
| keyword method | body exact; wrapper statements line only or wrong exact |
| do-block | call exact; body exact only with patch |
| closure | body exact only with patch; captured-variable `getfield` maps to whole call (wrong) |
| `@inbounds`, `@views` | exact; user code passes through macro unchanged |
| `@kwdef` | line only (struct line); no function node |
| package macro, escaped code | ambiguous when expansion repeats call on one line |
| package macro, body code | foreign_line: debuginfo names macro definition line; call site lost |
| `@generated` | generator output maps to unrelated node (`getindex` → ` 1:N`, wrong) |
| `@eval` loop | exact on template (`x * $factor`) |
| default constructor | line only (field line) |

Precision. Callee check compares IR callee name with callee spelled at mapped node (`callee_check` in `measure.jl`):
- 4744 match; 76 mismatch; 349 node not call. Lowering-inserted callees (about 6100: `getindex`, `getproperty` and others) are unchecked.
- Most non-call nodes are correct (`+=`, chained comparison, `2x`, macro call). About 45 are wrong (`block`, whole `function`).
- Wrong spans: 42 calls into keyword body mapped onto body expression; about 25 calls mapped to loop range (`zero` → `(j + 1):n`); about 45 block nodes. About 110 of 5169 checked spans: 2% wrong.
- Random sample of 40 unchecked lowered-name spans: 38 plausible.
- 6% of exact spans start with whitespace (` x * scale`). Trim leading trivia.

Time (warm compiler, 2285 methods, 2 threads): inference 7.3 to 8.6 s total; mapping 1.3 to 2.0 s total (median 0.2 ms, max 0.09 s per method). Mapping costs about 25% of unoptimized inference. Full run with package load: 23 s.

## Rust-style messages

`render.jl` builds `vague-type` message from mapping alone; output matches `findings.md:63-76`:

```
performance[vague-type]: `acc` changes type inside loop
  --> cases.jl:31:9
   |
29 |     acc = 0
   |     ------- starts as Int64
31 |         acc += xs[i]
   |         ^^^^^^^^^^^^ becomes Float64
```

- Primary and cause spans both come from statement mapping. Slot assignment maps to right side; widen to parent `=` node.
- Argument types (`x::Float64`) come from TypedSyntax `symtyps`: identifier node to type.
- Literal cause span: literal child of mapped call node.
- Fallback order: exact span; ambiguous → line span; `line_only` → line from `Base.IRShow.buildLineInfoNode(src.debuginfo, mi, i)`; `foreign_line` → nearest earlier statement with line inside definition; `missing` → method definition line, then coverage line.

## Gaps

1. CodeTracking front end drops first-line indentation; inner-constructor byte offsets shift (22 mismatches). It finds no source for closures, default constructors or macros (300 methods). Own file parse fixes both.
2. TypedSyntax accepts only named function roots. Closures and do-blocks need patch; patch raises closure exact share from 0 to 0.45.
3. Lowered debuginfo in Julia 1.13 is flat. Statements from macro body carry macro definition line; call site is lost. JuliaLowering provenance (S3) is only full fix.
4. `@generated` output and `kwcall` wrappers produce wrong exact spans. Skip mapping there; use definition line.
5. Heuristic mapping is about 2% wrong on checked calls. `definite` findings need validated spans.
6. TypedSyntax takes `JuliaSyntax.SyntaxNode` (package v1.0.2). `Base.JuliaSyntax` tree is different type; L1 tree cannot pass directly.

## Design consequences

- `findings.md:84`: "placed by lowering provenance" fails on Julia 1.13 lowering. Macro-body statements get macro definition line. Use nearest in-definition line, or JuliaLowering if S3 succeeds.
- `findings.md:61`: not every finding can carry byte span. Add span precision (`exact`, `line`) to `Span` (`architecture.md:29`). Renderer marks whole line when precision is `line`.
- `architecture.md:11`, `architecture.md:14`: Infer needs L1 tree. Vendor TypedSyntax mapping onto `Base.JuliaSyntax`, or parse with JuliaSyntax package in Infer. Vendoring also carries closure patch and precision fixes.
- `plan.md:21`: "macro output included" holds for user code passed through macros (`@inbounds`, `@views`, `@inline`). It fails for code macros create (`@kwdef`, `@deprecate`, macro bodies, `@generated`).
- `types.md:41`: "Source mapping through TypedSyntax.jl" holds for algorithm only. Drop CodeTracking.
- `plan.md:30` quality gate: validate spans (callee check) before `definite`; demote failed spans to line precision.
