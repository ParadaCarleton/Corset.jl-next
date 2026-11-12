# Pipeline

Layers Corset computes, and which analysis family reads each.

Layers run top to bottom. Check declares lowest layer it needs. Engine computes only layers that selected checks need. L2 runs after L3: macro expansion needs evaluated imports and package macros (S3). Scripts: L2 evaluates imports only; unresolved macros go to coverage line.

<div class="pipeline" role="img" aria-label="Analysis layers from syntax tree to dataflow, then findings, confidence filter, report and fix">
      <div class="layer"><div class="id">L1<small>syntax</small></div><div class="what">Lossless syntax tree, index by node kind<small>JuliaSyntax · per file · milliseconds</small></div><div class="fams"><span class="fam">A</span><span class="fam">B</span></div></div>
      <div class="divider">package code runs below · same process, target environment</div>
      <div class="layer"><div class="id">L3<small>module</small></div><div class="what">Loaded package: bindings, structs, method table<small>one load per run · cached by Manifest hash</small></div><div class="fams"><span class="fam">C</span></div></div>
      <div class="layer"><div class="id">L2<small>scope</small></div><div class="what">Lowering with scope resolution and source positions<small>JuliaLowering · per top-level form, include order · macros need L3</small></div><div class="fams"><span class="fam">H</span><span class="fam">B</span></div></div>
      <div class="layer"><div class="id">L4<small>types</small></div><div class="what">Typed IR for every package method<small>native inference cache · signatures from annotations · no package tests needed</small></div><div class="fams"><span class="fam">D</span></div></div>
      <div class="layer"><div class="id">L5<small>flow</small></div><div class="what">Effect and alias summary per method<small>own points-to summary inside method + callee summaries · bottom-up, Base included</small></div><div class="fams"><span class="fam">E</span></div></div>
      <div class="arrow" aria-hidden="true">↓</div>
      <div class="sink">
        <div><b>findings</b>span · rule · message · confidence · fix</div>
        <div><b>confidence filter</b>definite only, or definite + possible</div>
        <div><b>output</b>report · baseline · fixer batch</div>
      </div>
    </div>

Note: Family G (external tools) runs beside pipeline and reads source directories.
