"""
`untested-extension` (F88): extension trigger package missing from test dependencies.

## Description
Reports extension whose trigger package is neither direct dependency nor test dependency, and none of them loads it.

## Rationale
Extension loads only after every trigger package loads. Tests without trigger never run extension code.
Corset installs test dependencies to load extensions, so package rules skip untested extension too.
Rule reads Project.toml before load, so load error does not hide finding.

## Example
```toml
[weakdeps]
CUDA = "052768ef-5323-5732-b1bb-66c8b64840ba"

[extensions]
CUDAExt = "CUDA"
```

## Alternative
```toml
# test/Project.toml
[deps]
CUDA = "052768ef-5323-5732-b1bb-66c8b64840ba"
```

## Limitations
Run outside environment that resolves package reads direct lists only: trigger that other test dependency loads counts as missing.
Finding sits at extension module, so it shows only when run analyzes extension file.
"""
module UntestedExtension

using ...Facts

const NAME = Symbol("untested-extension")

"""Where to list `names` so tests install them, for package whose tests list dependencies as `test_deps` says."""
function test_fix(test_deps::TestDeps.T, names::String)::Fix
    test_deps == TestDeps.target && return manual_fix("add $names to `[targets].test` in Project.toml")
    test_deps == TestDeps.project && return manual_fix("add $names to `[deps]` of test/Project.toml")
    return manual_fix("add test/Project.toml with $names in `[deps]`")
end

"""Findings for each analyzed extension file whose extension has trigger that neither dependencies nor test dependencies load."""
function findings(facts::FactSet)::Vector{Finding}
    project = facts.project
    isnothing(project) && return Finding[]
    installed = Set([project.deps; project.tests; something(project.test_loads, Base.PkgId[])])
    by_path = Dict(file.path => file for file in facts.files)
    found = Finding[]
    for extension in project.extensions
        absent = filter(!in(installed), extension.triggers)
        file = get(by_path, extension.file, nothing)
        (isempty(absent) || isnothing(file)) && continue
        names = join(("`$(trigger.name)`" for trigger in absent), ", ", " and ")
        triggers = length(absent) == 1 ? "trigger" : "triggers"
        modules = forms(file, "module")
        primary = isempty(modules) ? Span(file.path, 1, 1, Precision.line) : span(file, children_of(first(modules))[1])
        push!(
            found, Finding(
                NAME, :untested_extension, Confidence.definite, "test dependencies lack $names, $triggers of extension `$(extension.name)`",
                Label(primary, "tests skip this extension"), Label[],
                "extension loads only after every trigger loads, so tests skip its code", test_fix(project.test_deps, names),
            ),
        )
    end
    return found
end

const ENTRY = RuleEntry(NAME, Group.safety, [88], Stage.syntax, findings)

end
