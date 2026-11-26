Source snapshot: MilesCranmer/julia-in-lean commit de862b5 (2026-11-07), https://github.com/MilesCranmer/julia-in-lean/tree/de862b5.
Bug citation form: `bugs/<id>.yaml` under julia-base/; issue numbers given only when README or YAML states them.
Bug corpus: 689 YAML write-ups; P0 6, P1 69, P2 398, P3 216 (README.md:211-216, recount matches).
Kinds: wrong-result 355, wrong-exception 185, documentation 58, missing-error 51, crash 24, hang 8, model-counterexample 8.
Group counts below come from keyword regex over title+summary; treat as approximate.
Full classified list: julia-in-lean/classified.txt; flat list: julia-in-lean/bugs.tsv.
Confidence field: "proven" = Lean refutation plus reproducer on Julia 1.13.2 and/or master; rule precision itself is always "likely" (untested).
Discourse: thread says ~400 bugs, 75 filed at time of post; README now says 107 filed (#64123..#64453).
Discourse: tim.holy states LinRange does not promise float exactness; treat LinRange findings as maybe-intended.
Discourse: no post discusses lint rules, `infer_effects`, or theorem export.

TASK 1. RULE SUGGESTIONS

R1 narrow-int range arithmetic (~198 bugs mention typemin/typemax/overflow; largest group)
Trigger: findfirst/findlast/intersect/reverse/sort/searchsorted*/length/findall(in(r1), r2)/`r .+ x`/`r .* x` on range whose inferred eltype is BitInteger narrower than Int, or any range spanning near typemin/typemax.
Cause: Base computes differences and quotients in element type, then wraps.
Message: "Range ops on Int8/Int16/UInt8 ranges compute in element type and can wrap; convert range to Int first."
Layer: inferred types.
Confidence: bugs proven; rule likely high precision for Int8/Int16, low frequency in real code.
Cite: ranges-operations-findfirst-overflow, array-range-target-search-overflow (#64122), range-findin-overflow, ranges-operations-unit-intersect-overflow, ranges-operations-step-intersect-overflow, ranges-operations-intersect-mixed-regression (#64131, master regression), ranges-operations-reverse-typemin (#64124), ranges-rational-int8-length-wraps, rangescov-ordinal-add-small-int (#64133), rangescov-steprangelen-sum-small-int (#64133), sort-range-search-overflow (#63399 known).

R2 unsigned range or unsigned step
Trigger: StepRange/StepRangeLen with Unsigned eltype or step, then reverse, negation `.-r`, slicing with reverse index, or broadcast with Float64.
Message: "Unsigned range step cannot represent descent; negation and reversal wrap or throw. Use signed range."
Layer: inferred types.
Confidence: bugs proven; rule likely.
Cite: ranges-operations-slice-unsigned-step (P1), broadcastviews-range-unsigned-float (P1), broadcastviews-range-negate-unsigned, range-srl-reverse-unsigned, range-srl-neg-unsigned, rangescov-steprange-unsigned-step-empty, ranges-ordinal-unsigned-step-last.

R3 typemax/typemin sentinel arguments
Trigger: constant `typemax(Int)`/`typemin(T)` (after const-prop) passed as count/length/index argument to first(s,n), last(s,n), chop(head=/tail=), lpad/rpad, Iterators.partition, nextfloat/prevfloat(::BigFloat, n), binomial(typemin(T), k), deleteat!(a, lo:typemax(Int)), reshape(..., typemax(Int), ...).
Trigger: literal `typemin(Int):typemax(Int)` passed to collect/length/==/rand/issorted.
Message: "typemax/typemin as sentinel overflows inside Base arithmetic; use explicit bound (e.g. length(x)) or clamp."
Layer: value ranges (constant propagation); syntax suffices for literal calls.
Confidence: bugs proven; rule likely high precision, moderate frequency (`first(s, typemax(Int))` idiom exists).
Cite: strings-first-n-overflow (#64143), strings-chop-head-overflow, strings-lpad-typemin (OutOfMemoryError), strings-partition-overflow, bignumscov-nextfloat-typemin (hang, P1), combinatorics-binomial-typemin (P1), arrayops-deleteat-range-overflow, ranges-collect-full-width-crash (segfault, #58245), ranges-length-overflow-silent, ranges-eq-wrapped-length, randomsampling-steprange-full-width, rangescov-issorted-full-width, reinterpretarrays-reshape-typemax-dim.

R4 typemin in signed arithmetic
Trigger: abs/negation/rem(x, y, RoundUp)/divrem/gcd/lcm/`maximum(abs, A)` where operand value range includes typemin(T).
Message: "abs(typemin(T)) and -typemin(T) wrap; result may be negative. Use widen or checked ops."
Layer: value ranges; inferred types alone gives too many hits.
Confidence: bugs proven; rule likely noisy without value ranges.
Cite: floatintcov-divrem-roundup-typemin (P1), div-bitinteger-remainder-equation-v2, reduce-maxabs-dims-typemin, intfuncscov-gcd-array-typemin, intfuncscov-gcd-mixed-typemin, intfuncs-lcm-array, complex-int-div-typemin, complex-pow-typemin.

R5 mixed-signedness integer division and reduction init
Trigger: div/fld/cld/rem/mod/fldmod/divrem with one Unsigned and one Signed argument (inferred types).
Trigger: prod/sum/count with `init` whose type is narrower than, or differs in signedness from, element type.
Message: "Mixed Unsigned/Signed division returns unsigned wrapped result; promote both operands explicitly."
Layer: inferred types.
Confidence: bugs proven; rule likely high precision, easy to implement.
Cite: int-div-unsigned-signed-promotes (P1: div(0x0a, Int16(-3)) == 0xfffd), intarith-division-fldmod-consistency, intarith-division-fldmod-consistency-v2, div-bitinteger-fldmod-contract-v2, reduce-prod-init-mixed-sign, bitarrays-count-init-wrap, reduce-sumdims-init-narrow.

R6 overflow-prone integer helpers
Trigger: nextpow/prevpow/ndigits(base<0)/checked_pow(unsigned, negative exponent)/Iterators.nth on cycle, with BitInteger argument not proven small.
Message: "nextpow(2, x) returns wrapped negative or zero on overflow; check x <= typemax(T) >> 1."
Layer: inferred types plus value ranges.
Confidence: bugs proven; rule likely low precision without ranges.
Cite: intarith-powers-nextpow-overflow (P1), intarith-checked-negative-pow (P1), intarith-powers-negative-base-typemin (P1), iterators-nth-cycle-overflow, dicts-sizehint-wrap-hang (hang).

R7 negative length/count/precision arguments
Trigger: argument named or positioned as length/n/count/precision/ntasks with value range including negatives: Base.wrap(Array, m, n), resize!(::BitVector, n), Base.split_rest(v, n), `r^n` for Regex, range(start; length=n) with UInt start, asyncmap(ntasks=f), Printf `%.*d` dynamic precision.
Message: "Negative length is not rejected here; result is invalid or memory unsafe. Validate n >= 0 first."
Layer: value ranges; syntax for negative literals.
Confidence: bugs proven; rule likely.
Cite: multidimcov-wrap-negative-length (P1), printf-negative-precision-int-oob (P1, #64202, out-of-bounds write), tuples-split-rest-negative, regexunicode-regex-pow-negative, ranges-keyword-negative-length, bitarrays-resize-negative, tasks-asyncmap-negative-ntasks-function (hang).

R8 empty collections
Trigger (narrow, lintable subset): first/last/findfirst/findlast/circshift!/sort(dims)/reverse(dims) on array whose size is statically zero in some dimension (e.g. zeros(0, n)); nextprod(()); Iterators.cycle of literally empty collection inside take.
Message: "Base method throws or misreports on empty input here; guard with isempty."
Layer: value ranges (shape tracking); dataflow.
Confidence: bugs proven; rule likely low recall (emptiness usually runtime).
Cite: multidim-findfirst-empty-matrix (P1), iterators-cycle-empty-length (P1), multidimcov-sizehint-first-empty (P1), bitarrays-circshift-empty, sort-dimension-copy-empty-axis, combinatorics-nextprod-empty, reduce-flatten-sum-empty, rangescov-bigfloat-colon-empty.
Unlintable remainder: most empty-input bugs need runtime emptiness; no static signal.

R9 Stateful iterator shared or probed
Trigger: same `Iterators.Stateful` (or eachline/IO-backed iterator) binding passed to two consumers (zip, product), or isempty/take(itr, 0) on Stateful.
Message: "Stateful iterator consumed by several consumers or probed by isempty; elements vanish. Collect first or use one consumer."
Layer: bindings plus inferred types.
Confidence: bugs proven; rule likely high precision.
Cite: iterators-take-isdone-zero (P1, #64151), iterators-zip-shared-stateful-completion, iterators-rest-isdone-state (#64152), iterators-product-stateful-done.

R10 aliasing of same binding into mutating call
Trigger: same binding passed twice to mutating function: append!(a, a, ...), prepend!(a, a, ...), mergewith!(f, d, d), copyto!(view(A,...), view(A,...)) with CartesianIndex index.
Trigger: resize!/push!/append! on result of vec(B)/reshape(B, n) where B is BitArray (dataflow).
Trigger: binding v used after `String(v)` (String takes ownership of v memory).
Message: "Mutating call reads argument that aliases destination; result depends on growth order. Pass copy(a)."
Layer: bindings for duplicate-argument form; dataflow for vec/reshape and String(v).
Confidence: bugs proven; rule likely high precision for duplicate-binding form.
Cite: arrayops-append-many-self, dictscov-iddict-map-rehash (P1), bitarrays-vec-resize-alias (P0, #64147), transcode-string-vector-alias (P1), broadcastviews-cartesian-alias, base64uuid-readbytes-shrinks.
Unlintable remainder: exprreflect-copy-quotenode-alias, bitsetscov-replace-generic-set (need runtime key overlap).

R11 Bool used as index or integer range endpoint
Trigger: inferred Bool scalar in index position of getindex/checkbounds/get on tuples, arrays, NamedTuple; `false:true` or StepRange with Bool endpoints; countfrom(true).
Message: "Bool index is integer index 0/1 here but logical elsewhere; use Int or a Bool mask."
Layer: inferred types.
Confidence: bugs proven; rule likely high precision.
Cite: tuples-getindex-bool, tuples-getindex-bool-range, reducecov-slice-bool-range, abstractarrays-checkbounds-real-index, range-bool-steprange-empty, iteratorscov-countfrom-eltype.

R12 offset axes into generic Base routines
Trigger: argument with inferred non-OneTo axes (OffsetArray, IdentityUnitRange view) passed to cat/hcat/vcat, findfirst on byte vectors, Iterators.nth with Unsigned index, view(V, :) of IdentityUnitRange view.
Message: "Base routine assumes 1-based axes for this argument type; results can be misplaced or out of bounds."
Layer: inferred types.
Confidence: bugs proven; rule likely, needs version gate.
Cite: abstractarrayspecs-cat-offset-axes (P1, returns uninitialized memory), reinterpretarrays-nested-slice-offset (P1), stringscova-search-offset-pattern-range (P1), iterators-nth-unsigned-offset, strings-search-offset-zero-byte, memsafety-accumulate-offset-axis-overflow (P1).

R13 membership and equality semantics on floats, missing, signed zero
Trigger: findall(in(b), x), issubset(a, b::Vector), isdisjoint, insorted, intersect where inferred eltype includes AbstractFloat or Missing.
Message: "in/issubset switch between == and isequal by container type and size; NaN and -0.0 results differ. Choose isequal or == explicitly."
Layer: inferred types.
Confidence: bugs proven; rule likely noisy (fires on all float sets).
Cite: array-findall-in-array-isequal (#64153), tuples-findall-in-isequal (#64153), dicts-issubset-vector-threshold, bitsetscov-isdisjoint-threshold, sorttuplescov-insorted-range-equivalence.
Related: F116 `float-key` flags float key lookup on `Set` and `Dict`, which always compare with `isequal`.
Trigger: cmp between BigFloat/BigInt/Rational and Float64 where operand may be -0.0.
Cite: bignums-cmp-signed-zero, bignums-gmp-comparison-ieee (#64167), promotion-cmp-rational-signed-zero.

R14 float range construction and membership
Trigger: `a:s:b` or UnitRange with Float endpoints and non-literal or extreme step (Inf, >1e300, subnormal); `x in r` for Float range or LinRange; equality between Float ranges.
Message: "Float range membership and equality use step arithmetic; use isapprox over collect(r) or integer index ranges."
Layer: inferred types; value ranges for Inf/huge step.
Confidence: bugs proven; LinRange subset maybe intended (Discourse, tim.holy).
Cite: floatranges-colon-infinite-step, floatranges-colon-underflow-nonempty, floatranges-in-overflow-throws, floatranges-linrange-step-overflow, rangescov-unitrange-float-last, rangescov-eq-twiceprecision, floatranges-linspace-tiny-endpoint (P1, #64136), floatranges-linrange-outside-endpoints (#64272).

R15 round with sigdigits/digits on extreme values
Trigger: round/floor/ceil(x; sigdigits=k or digits=k) where x value range includes near-floatmax, near power of ten, or subnormal.
Message: "sigdigits rounding returns 0.0 for some large or boundary inputs on affected Julia versions."
Layer: value ranges; version gate (PR #64624 fixes several on master per Discourse page 2).
Confidence: bugs proven; rule low precision, better as version advisory.
Cite: parseprint-round-digits-overflow-zero (#64142), floatfuncs-sigdigits-hidigit (P1), floatfuncs-sigdigits-idempotent, floatfuncs-digits-step-underflow.

R16 IO stream state misuse
Trigger: write/print to binding after close(binding) (dataflow).
Trigger: peek(io, T)/startswith(io, x)/truncate(io, n) between mark(io) and reset(io).
Trigger: replace(io, s, r => s"\1") with io inferred not IOBuffer, or IOBuffer opened append=true.
Message: "write after close returns 0 silently" / "peek clears existing mark" / "capture substitution needs non-append IOBuffer".
Layer: dataflow (close, mark); inferred types (replace).
Confidence: bugs proven; rules likely high precision.
Cite: streams-iostream-closed-write (P1), iobuffers-peek-clears-mark, stringutil-startswith-io-mark, iobuffers-truncate-mark, regexunicode-replace-capture-generic-io (P1), regexunicode-replace-capture-append (P1).

R17 effect assertions contradict body
Trigger: `@assume_effects` with :nothrow, :foldable, :terminates or :consistent on method whose body reaches error/throw or loop (compare against Base.infer_effects of unannotated body).
Message: "@assume_effects claims :nothrow but body can throw; compiler may drop exception handling."
Layer: inferred types (effect inference).
Confidence: bugs proven (escaped try/catch observed); rule likely high precision, rare in user code.
Cite: dicts-persistentdict-nothrow, bootcov-foldable-meta-effects.

R18 destructuring slurp in middle of short tuple
Trigger: `a, b..., c = t` where inferred tuple/NamedTuple length < number of non-slurp targets.
Message: "Middle slurp on too-short tuple reuses elements instead of throwing; check length(t)."
Layer: inferred types (tuple length known from type).
Confidence: bug proven (P1); rule likely high precision.
Cite: tuples-split-rest-state.

R19 Printf with BigFloat (version advisory)
Trigger: @printf/@sprintf/Printf.format with inferred BigFloat argument for %f/%e/%g, on affected versions.
Message: "Printf BigFloat path can write past buffer on Julia <fixed version>; convert or upgrade."
Layer: inferred types plus Julia version gate.
Confidence: bugs proven (P0 memory unsafety); rule precise but version-dependent.
Cite: printf-bigfloat-buffer-overflow (P0, #64185), printf-bigfloat-exact-fit-nul (P1, #64204).

R20 selectdim with CartesianIndex
Trigger: selectdim(A, d, I) with inferred CartesianIndex I.
Message: "selectdim with CartesianIndex can build out-of-bounds view; use view with explicit indices."
Layer: inferred types.
Confidence: bug proven (P0, #64175); rule high precision, version-gated.
Cite: multidim-selectdim-cartesian-oob.

R21 miscompile pattern (version advisory)
Trigger: in loop, `w = x isa C` assigned in one iteration, then `w && x isa String` in later iteration.
Layer: syntax plus scope (loop-carried binding).
Confidence: bug proven (P0, #64183, 1.14 regression); rule fragile, only worth as temporary advisory.
Cite: compiler-isa-flag-loop.

Unlintable bugs (one-line reason each)
C runtime/GC races (cruntime-*, c-runtime-*): runtime scheduling; model counterexamples, not reproduced in Julia.
dictscov-deepcopy-weakref (P0): GC timing decides failure.
files-cp-force-dangling-symlink, files-rm-recursive-symlink-slash, files-tempname-dangling-symlink: depend on filesystem state.
artifacts-slash-traversal, loading-named-env-path-escape: depend on runtime path strings; taint analysis only.
iocov-getpass-backspace, iocov-getpass-utf8: terminal input content.
platforms-detect-libstdcxx-csl: depends on loaded JLLs.
TOML, Markdown, Base64, shell-split, Regex, VersionNumber parse bugs (~137 text-format hits): depend on input text content.
bignums-parse-base-abort: needs runtime base value 1; lintable only for literal base=1.
dicts-persistentdict-objectid-collision: needs objectid collision.
nummisc-tanh-float32-nonmonotone, promotion-float-from-rational-nearest, bignums-bigfloat-rational-rounding: libm/rounding accuracy inside Base.
Wrong-exception-type bugs (185): call site cannot see exception type; lint can only warn on `catch e; e isa SpecificError` around affected calls (low value).
Documentation bugs (58): mismatch lives in Base docstrings, not user code.
channels-onceperthread-yield-hang: depends on task scheduling inside initializer.
dates-range-month-stop, dates-week-negative: depend on runtime date values.

TASK 2. SUMMARY-TABLE FEASIBILITY

Function count
Method inventory: 12,774 Base methods at pinned master; 11,686 marked modeled, 312 excluded, 776 todo (README.md:375; recount of coverage/methods/*.tsv matches).
Inventory spans 202 TSVs, one per Base source file (coverage/methods/).
"modeled" is inventory classification; README says it is not proof count or independent review.
Registry: 8,838 entries; 7,072 proven, 745 refuted, 1,021 todo (registry.tsv.metadata.jsonl recount matches).
Registry names 13,138 distinct `julia_functions` strings across 17,864 references.
Lean model files: 197 Base files under JuliaLean/base/; stdlib under JuliaLean/stdlib/.
Stdlib modules with entries: Sockets 25, Printf 20, Dates 20, Markdown 18, Random 12, Artifacts 12, Base64 7, Serialization 6, UUIDs 5, Unicode 3, CRC32c 1; Base has 8,709.
Also modeled: C runtime pieces (JuliaLean/src/*_c.lean, JuliaLean/CRuntime/); DynamicExpressions.jl in separate package (400 entries).

Property kinds (rough keyword counts over 8,838 English statements; overlapping)
Order/sortedness/source-order ~1,857 (many are "source order of calls preserved").
State preservation/unchanged ~1,795 (includes "preserves effects of failed call").
Length/size/count relation ~1,180.
Termination/hang ~811.
Result range/bounds ~639.
Equivalence with other method ~507.
Specific exception thrown ~423.
Memory safety/in-bounds ~386.
Element type ~185.
Aliasing ~134.
Explicit nothrow ~127; proven nothrow-like statements (incl. "returns a result for every allowed input") ~413.
Round-trip/inverse ~85.
1,013 statements are boilerplate ("The method satisfies the caller-visible result or state invariant stated by its method-specific property." appears 263 times); meaning lives only in Lean Prop.

Mutation and state
Pure functions use `Jl α := Except JlError α` (JuliaLean/Core.lean:35); errors are values: overflow, argument, bounds, inexact, divide, domain, method, EOF.
Mutating array code uses `VectorM := StateT (VectorHeap α) (Except Error)` (JuliaLean/base/array.lean:5123) and `MutationM := ExceptT Error (StateM (MutableMemory α))` (array.lean:5591).
Many models are monad-generic: `def push [Monad m] (...)` with callbacks for convert/growend/set (array.lean:2326-2340).
Generic models get concrete monad only in Bindings/ (10 files, e.g. Bindings/base/abstractarraymath.lean:160 liftVector).
Other subsystems use own state monads: Markdown StateT Stream (stdlib/Markdown/src/parse/util.lean:55), IOBuffer EStateM (Proofs/base/strings/annotated_io.lean), C subtype StateT (src/subtype_c.lean:251).
Purity readable from signature only for concretely typed defs: return type `Jl α` or plain value means no state.
Purity not readable for `[Monad m]`-generic defs; effect depends on supplied callbacks.
No uniform effect type across modules; script needs per-module monad table.

Version tracking and drift
Pins: release 1.13.2 `45b6d15e34b`; previous nightly `bbfa0ce4150`; target master `f755f49a9e4` (julia-base/ARCHITECTURE.md pinned-sources table).
Migration from bbfa0ce to f755f49 is in progress; ARCHITECTURE.md says so.
Each model def carries header `Julia source: base/<file>:<lines> @ <commit>` plus verbatim Julia source (~21,000 such headers).
coverage/SOURCE_COMMIT and memsafety/SOURCE_COMMIT both pin f755f49; scripts/check_coverage.py:214-216 fails on mismatch.
scripts/coverage_evidence.py hashes registry, audit and source snapshot (sha256); check_coverage reports "stale" evidence (check_coverage.py:285).
Upstream fix policy: merge upstream, update model, same statement flips refuted to proven; statement never edited (README "Flipping after upstream fixes").
1.13.2 differences recorded only in free-text entry notes.
No mechanism found for automatic re-sync on new Julia commits; drift is manual model update.
README says 19 historical per-file reviews predate migration and do not certify current source.

Regular shape for JSON export
Already JSON: registry.tsv.metadata.jsonl has id, julia_file, julia_functions, property, property_module, source, statement, status, theorem, theorem_module.
Join key exists: coverage/methods/*.tsv rows give file, line, endline, name, signature, status, entry id.
Signature keys are not regular: forms include `push!@3665`, `method beginning at base/loading.jl:3831` (175 refs), `unary +`, `Base._base`, line-suffixed `@NNN` (1,389 refs), and broken splits like `getindex(t::Tuple` + `i::Int)`.
Mapping to Julia `Method` objects needs file:line from coverage TSVs, valid only at commit f755f49.
Property semantics have no structured fields (precondition, postcondition kind, exception set); only English statement plus Lean Prop.
Lean Props use model-specific types (Num, Rng, HeapArray) and callback parameters; no common schema.
Verdict: export of (method file:line, signature string, entry id, status, English statement, source sentence) is mechanical.
Verdict: export of machine-usable summaries (nothrow-if-P, result-range, length relation) needs per-entry classification by person or LLM; not scriptable from Lean syntax.
Refuted entries plus reproducers are directly usable as "known-bad input" records keyed by bug id.

Properties beyond `Base.infer_effects`
infer_effects gives type-level, unconditional bits (consistent, effect_free, nothrow, terminates, notaskstate, inaccessiblememonly).
Conditional nothrow: e.g. "tryparse returns nothing exactly when parse throws" (parseprint-tryparse-nothing-iff-parse-throws).
Exact exception type per input class (inexactError vs argumentError vs boundsError), modeled in JlError.
Result value range: e.g. MPZ.cmp returns -1, 0 or 1 (registry entry on `MPZ.cmp`).
Length/cardinality relations: e.g. reverse preserves cardinality (ranges-operations-reverse-typemin).
Error atomicity: state unchanged when call throws (e.g. arrayops-deleteat-error-partial refutes it for deleteat!).
Call-order and callback-protocol properties ("key discovery precedes search").
Aliasing and memory-safety claims (memsafety/sites-*.tsv; 1,194 sites, 899 unsettled).
Per-value termination (hang findings, e.g. bignumscov-nextfloat-typemin); infer_effects :terminates is type-level only.
Cross-method equivalence (fldmod vs mod, checkbounds vs getindex).
Effects themselves appear only as objects of refutation: dicts-persistentdict-nothrow refutes Base `:nothrow` annotation; bootcov-foldable-meta-effects.

Unclear or unavailable
Exact mapping bug id to filed issue number is incomplete: YAML `duplicates` mixes filed issues and prior issues.
Discourse page 1 and 2 summaries came through WebFetch summarizer; quotes not verified verbatim.
Keyword-based group counts and property-kind counts are heuristic.
DynamicExpressions property kinds not analyzed.
