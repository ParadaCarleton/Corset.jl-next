using Documenter, Corset
using Corset.Facts: Group
using Corset.Rules: REGISTRY

"""Names of rules in `group`, as inline code."""
group_rules(group::Group.T)::String = join(("`$(entry.name)`" for entry in REGISTRY if entry.group == group), ", ")

"""Rules page: group table, then one section per registry rule with its module docstring."""
function rules_page()::String
    table = join(("| `$group` | $(group_rules(group)) |" for group in instances(Group.T)), "\n")
    sections = map(REGISTRY) do entry
        """
        ## `$(entry.name)`

        Group `$(entry.group)`, stage `$(entry.stage)`.

        ```@docs
        Corset.Rules.$(nameof(parentmodule(entry.run)))
        ```
        """
    end
    header = """
    # Rules

    The [project kind](guide.md#Project-kind) sets the level of each group.
    `corset explain <rule>` prints the text of a rule in the terminal.

    | Group | Rules |
    | --- | --- |
    $table
    """
    return join([header; sections], "\n")
end

# Generated from the registry, so the page lists every rule; git ignores the file.
write(joinpath(@__DIR__, "src", "rules.md"), rules_page())

makedocs(;
    sitename = "Corset.jl",
    authors = "Carlos Parada",
    modules = [Corset],
    # User manual: rule docs come from the registry; Facts exports are internal rule API.
    checkdocs = :none,
    format = Documenter.HTML(canonical = "https://paradacarleton.github.io/Corset.jl/stable"),
    pages = ["Home" => "index.md", "Guide" => "guide.md", "CLI" => "cli.md", "Rules" => "rules.md"],
    warnonly = false,
)

deploydocs(repo = "github.com/ParadaCarleton/Corset.jl.git", push_preview = true)
