# Pipeline

Analysis stages Corset computes, in pipeline order. Each stage computes facts once per run; rules read them.

Stages run top to bottom. Stage not built yet gives no facts; no rule reads it until it ships. Rule declares two stages: `stage` for findings and `fix_stage` for fixes, never earlier. Engine computes only stages selected rules need for either. `scope` runs after `package`: macro expansion needs evaluated imports and package macros. Scripts: `scope` evaluates imports only; unresolved macros go to coverage line.

<div class="pipeline" role="img" aria-label="Analysis stages from syntax tree to effect facts, then findings, confidence filter, report and fix">
      <div class="layer"><div class="id">syntax</div><div class="what">Lossless syntax tree, index by node kind<small>JuliaSyntax · per file · milliseconds</small></div></div>
      <div class="divider">package code runs below · same process, target environment</div>
      <div class="layer"><div class="id">package</div><div class="what">Loaded package: bindings, structs, method table<small>one load per run · cached by Manifest hash</small></div></div>
      <div class="layer"><div class="id">scope</div><div class="what">Lowering with scope resolution and source positions<small>JuliaLowering · per top-level form, include order · macros need package</small></div></div>
      <div class="layer"><div class="id">inference</div><div class="what">Typed IR for every eligible package method<small>native inference cache · signatures from annotations · no package tests needed</small></div></div>
      <div class="layer"><div class="id">effects</div><div class="what">Effect facts per method<small>method alone · callee names stand in for callee bodies</small></div></div>
      <div class="layer"><div class="id">lifecycle</div><div class="what">Local def-use per array<small>statement events of <code>effects</code> · per method</small></div></div>
      <div class="arrow" aria-hidden="true">↓</div>
      <div class="sink">
        <div><b>findings</b>span · rule · message · confidence · fix</div>
        <div><b>confidence filter</b>definite only, or definite + possible</div>
        <div><b>output</b>report · baseline · fixer batch</div>
      </div>
    </div>

Note: `external` stage (Aqua.jl, `Test.detect_ambiguities`, ExplicitImports.jl) runs after `package` and reads loaded modules and source.
