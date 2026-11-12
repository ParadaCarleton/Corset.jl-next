using Documenter, CorsetLegacy

DocMeta.setdocmeta!(CorsetLegacy, :DocTestSetup, :(using CorsetLegacy); recursive = true)

makedocs(;
    sitename = "Corset.jl",
    authors = "Carlos Parada",
    modules = [CorsetLegacy],
    checkdocs_ignored_modules = [CorsetLegacy.WorkloadPackage],
    format = Documenter.HTML(canonical = "https://paradacarleton.github.io/Corset.jl/stable"),
    pages = [
        "Home" => "index.md", "Guide" => "guide.md", "CLI" => "cli.md", "Rules" => "rules.md", "API" => "api.md",
        "Internals" => ["Source rules" => "internals/source.md", "Typed-code rules" => "internals/typed.md", "Array rules" => "internals/arrays.md", "Runner" => "internals/runner.md", "Fixers" => "internals/fixers.md"],
    ],
    warnonly = false,
)

deploydocs(repo = "github.com/ParadaCarleton/Corset.jl.git", push_preview = true)
