"""Regenerate footgun, family and check sections of rules-rewrite.html and coverage table of rules-rewrite-history.md.

Edit data lists here, then run: python -I docs/design/build_footguns.py
"""
import html, os, re, sys

C, P, M, R = "correctness", "performance", "composability", "readability"

# (stable id, area, footgun, example, group, family, note); ids never reused; backticks become <code>
FOOTGUNS = [
    (1, "syntax", "Space before minus in array literal concatenates", "`[1 -2]` is 1×2 matrix", C, "A", ""),
    (2, "syntax", "Range in brackets is one-element vector", "`[1:3]`", C, "A", ""),
    (3, "syntax", "Juxtaposition binds tighter than reader expects", "`2^2x == 2^(2x)`, `1/2x`", C, "A", ""),
    (4, "syntax", "`where` after result annotation binds result type", "`f(x::T)::T where {T}`", C, "A", "Errors, or silently binds global `T` if one exists; report both. Upstream rejected precedence change (JuliaLang/julia#21847)."),
    (5, "numbers", "Literal or constant changes input type", "`x::Float32 * 0.5`, `x::Int32 * 2`", M, "D", "Report when converting literal to input type would change type of escaping value. Applies to generic and fixed arguments."),
    (6, "numbers", "Float constant where irrational exists; promotes generic code", "`sqrt(2)`, `3.14159`", M, "D", "Suggest `π`, IrrationalConstants.jl (`sqrt2`)."),
    (7, "numbers", "Signed `%` and `÷` round toward zero", "`-1 % 3 == -1`", C, "D", ""),
    (8, "numbers", "Mixed signed and unsigned division", "`div(-1, UInt(2))`", C, "D", ""),
    (9, "numbers", "Float-to-integer constructor throws on fractions", "`Int(2.5)`", C, "D", ""),
    (10, "numbers", "Approximate compare to zero without `atol` is always false", "`x ≈ 0`", C, "A", ""),
    (11, "numbers", "`Bool` used as index", "`v[true]`", C, "D", ""),
    (12, "numbers", "Integer overflow wraps silently", "`typemax(Int) + 1`", C, "D", "Later; off by default. Needs value ranges."),
    (13, "numbers", "Result annotation converts instead of checking", "`f(x)::Float64 = x` turns `Float32` into `Float64`", C, "D", "Report when inferred result needs conversion; annotation then acts as type check."),
    (14, "types", "Invariant parameter rejects intended arguments", "`f(::Vector{Real})` rejects `Vector{Float64}`", C, "C", ""),
    (15, "types", "Fixed annotation blocks generic callers", "`x::Float64`, `x::AbstractFloat`, `v::AbstractVector{Float64}` reject `Dual`", M, "C", "Fixed: names specific number type, `AbstractFloat`, or concrete container anywhere in annotation. Fix: type parameter."),
    (16, "types", "Hard-coded `Array` drops caller's array type", "`zeros(n)` inside method that got `CuArray`", M, "D", ""),
    (17, "types", "Variable, result or closure capture with vague inferred type", "`acc = 0` then `acc += 0.5`", P, "D", "Capture may need own fix (`let`, pass as argument)."),
    (18, "types", "Struct field with vague type", "`x::Real`, `x::Vector`", P, "C", ""),
    (19, "types", "Mutable struct where immutable works", "`mutable struct`; struct of mostly `Ref` fields", P, "D", ""),
    (20, "types", "Ad-hoc union of unrelated types where sum type belongs", "`Union{Circle, Square, Error}`", P, "D", ""),
    (21, "types", "Empty literal has `Any` element type", "`[]`, `Dict()`", P, "A", ""),
    (22, "types", "`==` defined without `hash`", "`Dict` and `Set` disagree with `==`", C, "C", ""),
    (23, "types", "Method named like Base function without `Base.` shadows it", "`length(x::MyT) = …`", C, "C", ""),
    (24, "types", "Methods differ only in keywords; later one overwrites", "`f(x; a)` and `f(x; b)`", C, "C", "Keywords take no part in dispatch. Julia 1.10+ errors in packages; check covers scripts and explains cause."),
    (25, "types", "Type piracy", "`Base.:+(::Int, ::String)`", M, "G", ""),
    (26, "types", "Behavior depends on inference result", "`Core.Compiler.return_type`", M, "A", ""),
    (83, "types", "Call can never succeed", "no matching method; undefined global or field", C, "D", "Package call inferred `Union{}` without explicit `throw`. JET is test reference."),
    (84, "types", "Public struct has no abstract supertype; users cannot extend", "`struct Model` → `struct Model <: AbstractModel`", M, "C", "Public structs only."),
    (27, "compile", "Call resolved at run time", "call on `Any`", P, "D", ""),
    (28, "compile", "Splat of variable-length collection", "`f(xs...)`, `xs::Vector`", P, "D", ""),
    (29, "compile", "Recursion with argument types that nest each call", "`f(x) = f((x,))`", P, "D", ""),
    (30, "compile", "Too many specializations on `Function` or `Type` argument", "one method, 500 closure types", P, "C", "Predict from source: C finds methods that specialize on argument; A counts distinct closures or types passed at package call sites."),
    (31, "arrays", "Loop over scalar runs once", "`for i in 4`, `for i in length(v)`", C, "D", ""),
    (32, "arrays", "Temporary array built only to be consumed once", "`sum(f.(x))` → `sum(f, x)`; `collect` of iterator used once", P, "B", "Enforceable part of stay-lazy goal."),
    (33, "arrays", "Uninitialized element read before write", "`similar(x)` then `sum`", C, "B", ""),
    (34, "arrays", "Placeholder value looks like data after partial fill", "`zeros(n)`, half written", C, "B", ""),
    (35, "arrays", "`fill` shares one mutable object", "`fill(zeros(3), n)`", C, "A", ""),
    (36, "arrays", "`1:length(A)` assumes 1-based indices", "`OffsetArray` breaks it", M, "A", ""),
    (37, "arrays", "Index safety removed without proof", "`@inbounds` on unchecked index", C, "D", ""),
    (38, "arrays", "String indexed by character count", "`s[i]` for `i in 1:length(s)`", C, "D", ""),
    (39, "arrays", "Never-written constant array allocates", "`ones(n)` read only", P, "B", ""),
    (40, "arrays", "Read-only slice copies", "`sum(A[:, i])`", P, "B", ""),
    (41, "arrays", "Broadcast rebinds preallocated buffer", "`x = f.(y)`", P, "B", ""),
    (42, "arrays", "Inner loop over non-first index", "`for i, j; A[i, j]`", P, "A", "Possible only."),
    (43, "arrays", "Search inside loop over same collection", "`x in v` per element of `v`", P, "D", ""),
    (44, "arrays", "Fold concatenates one piece at a time", "`reduce(vcat, parts)` in loop", P, "A", ""),
    (45, "arrays", "Matrix function where elementwise was meant", "`exp(A)`", C, "D", "Later; off by default."),
    (46, "arrays", "Adjoint conjugates complex data", "`v'` on `ComplexF64`", C, "D", "Later; off by default."),
    (47, "containers", "Mutable key mutated after insert", "`Dict{Vector{Int}, …}`", C, "D", ""),
    (48, "containers", "Container mutated while iterating", "`delete!(d, k)` in `for k in keys(d)`", C, "E", ""),
    (49, "containers", "Code relies on `Dict` order", "`Dict` iterated into output", C, "D", "Later; off by default."),
    (50, "containers", "Same container passed twice to mutating call", "`append!(a, a)`", C, "E", ""),
    (51, "containers", "`Iterators.Stateful` consumed twice", "`isempty(s)` then `for x in s`", C, "E", ""),
    (52, "containers", "`missing` reaches condition", "`if x > 0` with `x::Union{Missing, Int}`", C, "D", ""),
    (53, "effects", "Function writes argument or global without `!`", "`normalize(v)` changes `v`", C, "E", ""),
    (54, "effects", "Call has no effect and result is unused", "`f(x)` returns `nothing`, writes nothing", C, "E", ""),
    (86, "effects", "`!` function writes nothing; callers drop its result", "`normalize!(v)` returns new vector", C, "E", ""),
    (55, "effects", "Hidden input: mutable global, `ScopedValue`, global RNG", "`rand()` in package code", C, "E", ""),
    (56, "effects", "Anonymous function impure: captures mutable state", "`filter(x -> x in seen, xs)`, `seen::Set`", C, "E", "Named functions follow `!` convention; anonymous ones stay pure. Read-only capture counts."),
    (57, "effects", "Closure rebinds captured variable; `Core.Box`", "`n = 0; f = () -> (n += 1)`", P, "H", ""),
    (58, "effects", "`@assume_effects` claim false", "`:consistent` on body that reads global", C, "E", ""),
    (59, "effects", "Catch handles every error", "`catch; end`", C, "A", ""),
    (60, "effects", "Same statement twice in block", "copy-paste duplicate", C, "A", ""),
    (61, "scope", "Top-level loop assigns global; REPL and file differ", "`for …; total += x; end` in script", C, "H", ""),
    (62, "scope", "Variable first assigned in `try` read after it", "`try; y = f(); end; y`", C, "H", ""),
    (63, "scope", "Function defined by `eval` called in same world", "`@eval g() = 1; g()`", C, "H", ""),
    (64, "scope", "Same file included twice", "two copies of module", C, "A", ""),
    (65, "modules", "Name reached through bare `using`", "two packages export `solve`", M, "G", ""),
    (66, "modules", "Use of other module's internal name", "`Base._foo`", M, "G", ""),
    (67, "modules", "Import placed in file that does not use it", "`using LinearAlgebra` in `src/Pkg.jl` for `src/solve.jl`", R, "G", ""),
    (68, "concurrency", "Buffer indexed by `threadid()`", "`bufs[threadid()]`", C, "A", ""),
    (69, "concurrency", "Unsynchronized update in threaded loop", "`acc += x` in `@threads`", C, "H", ""),
    (70, "concurrency", "Task result never waited; errors vanish", "`@spawn work()`", C, "A", ""),
    (71, "readability", "Argument or result without type", "`f(x) = …`", R, "A", "With result-conversion check, annotations act as type checks. Fixer fills result type from inference. `::Any` opts out."),
    (72, "readability", "One-letter name", "`q = …`", R, "A", "Exempt: type names and parameters; `i`, `j`, `k` as indices."),
    (73, "readability", "Explicit `return` mixed with implicit last value", "", R, "A", "Narrow by design. Requiring `return` everywhere forces `return nothing`, which fights formatters (Runic) and creates dead code."),
    (74, "readability", "Comment where docstring belongs", "`# adds x` above function", R, "A", ""),
    (76, "readability", "Copied code block", "", R, "G", "Off by default; jscpd finds near-duplicates, needs Node."),
    (77, "readability", "File too long", "", R, "A", ""),
    (78, "readability", "Struct with too many fields", "", R, "A", ""),
    (79, "readability", "Related fields belong in nested struct, table or array", "`governor_name`, `governor_age` → `governor.name`", R, "A", ""),
    (80, "readability", "Module without docstring", "", R, "A", ""),
    (81, "readability", "C types outside C calls", "`Cint`", R, "A", ""),
    (82, "readability", "Project-banned name or pattern", "config list", R, "A", ""),
]


def code(text: str) -> str:
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", html.escape(text, quote=False))


def row(ident: int, area: str, footgun: str, example: str, group: str, family: str, note: str) -> str:
    cells = [f"F{ident}", area, code(footgun), code(example), f'<span class="chip g-{group}">{group}</span>', family, code(note)]
    return f'      <tr data-group="{group}">' + "".join(f"<td>{cell}</td>" for cell in cells) + "</tr>"


buttons = "\n".join(
    f'    <button type="button" data-filter="{name}" aria-pressed="{str(name == "all").lower()}">{name}</button>'
    for name in ("all", C, P, M, R)
)
BY_ID = {item[0]: item for item in FOOTGUNS}
assert len(BY_ID) == len(FOOTGUNS)
rows = "\n".join(row(*item) for item in FOOTGUNS)
section = f"""<section id="footguns">
  <h2>Footguns</h2>
  <p>Source of truth for rewrite. Each line names one problem Corset prevents. Engines and checks derive from this list; old rule names appear only in coverage appendix.</p>
  <div class="filter" role="group" aria-label="Filter footguns by group">
{buttons}
  </div>
  <div class="scroll">
  <table data-table>
    <thead><tr><th>ID</th><th>Area</th><th>Footgun</th><th>Example</th><th>Group</th><th>Family</th><th>Note</th></tr></thead>
    <tbody>
{rows}
    </tbody>
  </table>
  </div>
</section>

"""
page_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rules-rewrite.html")
page = open(page_path).read()
page = re.sub(r'<section id="footguns">.*?</section>\n\n', "", page, flags=re.S)
page = page.replace('<section id="pipeline">', section + '<section id="pipeline">', 1)
open(page_path, "w").write(page)
print(len(FOOTGUNS))

# families section, generated from same mapping
FAMILY_INFO = [
    ("A", "Syntax patterns", "One tree walk per file. Checks match node shapes. Candidate base: Argus.jl (check license and API stability first)."),
    ("B", "Array lifecycle", "Local def-use per array: created, written, read before write, resized, escapes, read once."),
    ("C", "Module inspection", "Loaded package without inference: bindings, structs, signatures, method table, specialization heuristics."),
    ("D", "Typed-IR scan", "One inference per package method; stand-in types replace generic arguments. One pass per inferred frame. One shared definition of vague type (union policy)."),
    ("E", "Effect and alias summary", "Per method: writes to arguments, writes to globals, result aliases global state."),
    ("H", "Scope", "Lowered scopes per file: bindings, soft scope, captures, boxes, task spawns."),
    ("G", "External tools", "Wrap tool output as findings: Aqua.jl, ExplicitImports.jl, jscpd."),
]
cards = []
for letter, title, text in FAMILY_INFO:
    chips = "".join(
        f'<span class="chip g-{item[4]}" title="{html.escape(item[2].replace("`", ""))}">F{item[0]}</span>'
        for item in FOOTGUNS if item[5] == letter
    )
    cards.append(f'    <div class="family"><h3><span>{letter}</span>{title}</h3><p>{text}</p><div class="rules">{chips}</div></div>')
families = (
    '<section id="families">\n  <h2>Analysis families</h2>\n'
    '  <p>Each family is one analysis. Checks inside family share its code and output. Chips are footgun IDs; hover for text.</p>\n'
    '  <div class="families">\n' + "\n".join(cards) + "\n  </div>\n</section>"
)
page = open(page_path).read()
page = re.sub(r'<section id="families">.*?</section>', lambda _: families, page, count=1, flags=re.S)
open(page_path, "w").write(page)

# coverage appendix: old rule or idea -> footgun IDs, or reason dropped
COVERAGE = [
    ("main", "unstable-variable", "17", ""), ("main", "unstable-return", "17", ""),
    ("main", "unstable-anon-fun", "17", ""),
    ("main", "runtime-dispatch", "27", ""), ("main", "recursion-limit", "29", ""),
    ("main", "float-widening", "5", ""), ("main", "float64", "5", "Duplicate."),
    ("main", "abstract-field", "18", ""), ("main", "mutable-struct", "19", ""),
    ("main", "wide-struct", "78", ""), ("main", "repeated-prefix", "79", ""),
    ("main", "repeated-statement", "60", ""), ("main", "return-type", "26", ""),
    ("main", "concrete-arg", "15", ""), ("main", "concrete-return", "13 71", ""),
    ("main", "annotation", "71", ""), ("main", "c-type", "81", ""), ("main", "ref", "19", "`Ref` as C helper dropped; struct of `Ref`s kept."),
    ("main", "one-letter", "72", ""), ("main", "file-length", "77", ""),
    ("main", "forbidden-pattern", "82", ""), ("main", "where-return", "4", ""),
    ("main", "constant-array", "39", ""), ("main", "nan-initializer", "34", ""),
    ("main", "broad-catch", "59", ""), ("main", "quadratic-scan", "43", ""),
    ("main", "quadratic-vcat", "44", ""), ("main", "misplaced-import", "67", ""),
    ("main", "hidden-input", "55", ""), ("main", "non-public-access", "66", ""),
    ("main", "unmarked-mutation", "53", ""), ("main", "bang", "53 54", "Split into missing `!` and no-op call."),
    ("main", "impure-anon-fun", "56 57", "Split: impure capture, boxed capture."),
    ("main", "overspecialized-anon-fun", "30", ""), ("main", "jscpd", "76", ""),
    ("main", "jet", "83", "Cheap cases in D scan; JET for rest."),
    ("main", "fatou", "", "External; not reviewed."),
    ("main", "nothing-return", "", "Dropped."), ("main", "non-atomic-write", "", "Dropped."),
    ("main", "struct-constant", "", "Dropped: Revise workaround."),
    ("main", "derived-constant", "", "Dropped: Revise workaround."),
    ("main", "range-guard", "", "Dropped: one past bug."),
    ("open work", "unwritten-undef", "33", ""), ("open work", "no-inbounds", "37", ""),
    ("open work", "abstract-element", "21", ""), ("open work", "invariant-parameter", "14", ""),
    ("open work", "abstract-float", "15", ""), ("open work", "concrete-annotation", "13 15", ""),
    ("open work", "enumerated-union", "20", ""), ("open work", "literal-array", "16", ""),
    ("open work", "similar-array", "16", ""), ("open work", "banned-name", "82", ""),
    ("open work", "irrational-constant", "6", ""), ("open work", "comment-docstring", "74", ""),
    ("open work", "while-true-return", "", "Dropped."), ("open work", "collect", "16 32", "Goal: `collect` returns `Vector`, drops array type."),
    ("open work", "file-module", "80", "Docstring part only."),
    ("open work", "silent-existence-filter", "", "Dropped: reasonable code."),
    ("open work", "any-supertype", "84", "Extensibility."), ("open work", "dims-keyword", "32", "Stay-lazy goal; `dims` itself fine."),
]

# checks: unit of config, opt-out and group; one group per check
CHECKS = [
    ("ambiguous-concat", [1], ""), ("bracketed-range", [2], ""), ("juxtaposition", [3], ""),
    ("where-binding", [4], "Fixer adds parentheses."),
    ("type-disruption", [5, 6, 16], "Stand-in engine. Kinds: literal, float constant, array type."),
    ("signed-division", [7, 8], ""), ("inexact-conversion", [9], ""), ("approx-zero", [10], ""),
    ("bool-index", [11], ""), ("overflow", [12], "Later."),
    ("result-conversion", [13], "With `annotation`, makes annotations checked."),
    ("invariant-parameter", [14], ""), ("narrow-signature", [15], ""),
    ("vague-type", [17, 18, 20], "Union policy. Kinds: local, result, capture, field, union. Union of input type and literal type goes to `type-disruption`."),
    ("mutable-struct", [19], ""), ("untyped-empty", [21], "Fixer adds element type."),
    ("eq-without-hash", [22], ""), ("shadowed-base", [23], ""), ("keyword-overwrite", [24], ""),
    ("piracy", [25], "Aqua.jl."), ("inference-dependent", [26], ""), ("never-succeeds", [83], ""),
    ("closed-struct", [84], ""),
    ("runtime-dispatch", [27], ""), ("dynamic-splat", [28], ""), ("growing-recursion", [29], ""),
    ("specialization-blowup", [30], ""), ("scalar-loop", [31], ""), ("temporary-array", [32], ""),
    ("unwritten-element", [33, 34], "Kinds: undef read, placeholder read."),
    ("shared-fill", [35], ""), ("one-based-range", [36], "Fixer: `eachindex`."),
    ("unverified-inbounds", [37], ""), ("string-index", [38], ""), ("constant-array", [39], "Fixer: FillArrays.jl."),
    ("slice-copy", [40], ""), ("broadcast-rebind", [41], ""), ("loop-order", [42], "Possible only."),
    ("quadratic", [43, 44], "Kinds: scan, concatenation."),
    ("matrix-function", [45], "Later."), ("conjugating-adjoint", [46], "Later."),
    ("mutable-key", [47], ""), ("iteration-mutation", [48], ""), ("dict-order", [49], "Later."),
    ("self-alias", [50], ""), ("stateful-reuse", [51], ""), ("missing-condition", [52], ""),
    ("bang-convention", [53, 86], "Kinds: missing, spurious. Methods added to other module's `!` function exempt. See `!` convention."), ("unused-call", [54], ""), ("hidden-input", [55], ""),
    ("impure-lambda", [56], ""), ("boxed-capture", [57], ""), ("false-effects", [58], ""),
    ("broad-catch", [59], ""), ("duplicate-statement", [60], ""),
    ("soft-scope", [61], ""), ("try-scope", [62], ""), ("world-age", [63], ""), ("double-include", [64], ""),
    ("implicit-import", [65], "ExplicitImports.jl."), ("internal-access", [66], "ExplicitImports.jl."),
    ("misplaced-import", [67], "Fixer moves imports."),
    ("threadid-buffer", [68], ""), ("threaded-race", [69], ""), ("orphan-task", [70], ""),
    ("annotation", [71], ""), ("one-letter", [72], ""), ("mixed-return", [73], ""),
    ("docstring", [74, 80], "Kinds: comment above function, module without docstring."),
    ("duplicate-code", [76], "jscpd. Off by default."), ("file-length", [77], ""), ("wide-struct", [78], ""),
    ("field-prefix", [79], ""), ("c-type", [81], ""), ("banned", [82], "One config list; each entry names its group."),
]
CHECK_OF = {ident: name for name, ids, _ in CHECKS for ident in ids}
assert sorted(CHECK_OF) == sorted(BY_ID) and sum(len(ids) for _, ids, _ in CHECKS) == len(BY_ID), "each footgun in one check"
for name, ids, _ in CHECKS:
    assert len({BY_ID[ident][4] for ident in ids}) == 1, f"{name}: one group per check"

check_rows = "\n".join(
    f'      <tr data-group="{BY_ID[ids[0]][4]}"><td><code>{name}</code></td>'
    f'<td><span class="chip g-{BY_ID[ids[0]][4]}">{BY_ID[ids[0]][4]}</span></td>'
    f'<td>{" ".join(sorted({BY_ID[ident][5] for ident in ids}))}</td>'
    f'<td>{"<br>".join(f"F{ident} {code(BY_ID[ident][2])}" for ident in ids)}</td><td>{code(note)}</td></tr>'
    for name, ids, note in CHECKS
)
checks = f"""<section id="checks">
  <h2>Checks</h2>
  <p>Check is unit of config, opt-out and group. It covers one footgun, or several with same group and same analysis. Kinds inside check give distinct messages and fixes.</p>
  <div class="filter" role="group" aria-label="Filter checks by group">
{buttons}
  </div>
  <div class="scroll">
  <table data-table>
    <thead><tr><th>Check</th><th>Group</th><th>Family</th><th>Footguns</th><th>Note</th></tr></thead>
    <tbody>
{check_rows}
    </tbody>
  </table>
  </div>
</section>

"""
page = open(page_path).read()
page = re.sub(r'<section id="checks">.*?</section>\n\n', "", page, flags=re.S)
page = page.replace('<section id="confidence">', checks + '<section id="confidence">', 1)
page = re.sub(r"<b>\d+</b> checks", f"<b>{len(CHECKS)}</b> checks", page)
page = re.sub(r"<b>\d+</b> footguns", f"<b>{len(FOOTGUNS)}</b> footguns", page)
open(page_path, "w").write(page)

# coverage of old names goes to history markdown
def plain(text: str) -> str:
    return text.replace("|", "\\|")

coverage_rows = "\n".join(
    f"| {source} | `{name}` | "
    + ("<br>".join(f"F{number} {plain(BY_ID[int(number)][2])}" for number in ids.split()) or "—")
    + f" | {', '.join(sorted({'`' + CHECK_OF[int(number)] + '`' for number in ids.split()})) or '—'} | {plain(note)} |"
    for source, name, ids, note in COVERAGE
)
coverage = ("<!-- coverage -->\n| Source | Old rule | Footguns | Check | Note |\n|---|---|---|---|---|\n"
            + coverage_rows + "\n<!-- /coverage -->")
history_path = os.path.join(os.path.dirname(page_path), "rules-rewrite-history.md")
history = open(history_path).read()
history = re.sub(r"<!-- coverage -->.*?<!-- /coverage -->", lambda _: coverage, history, flags=re.S)
open(history_path, "w").write(history)
