# Corset.jl

Corset is a code-quality checker for Julia. It reports likely bugs, performance traps and code that is hard to read.
Each finding shows the code, the reason and a fix. Corset applies the fixes that are safe for your project.

Corset checks packages, applications and scripts. Its rules read the syntax tree of each file, and the loaded package.

## Install

Corset is not in the General registry. Add the `corset` app from its repository:

```julia
pkg> app add https://github.com/ParadaCarleton/Corset.jl-next
```

Pkg puts the app in `~/.julia/bin`. Add that directory to `PATH`.
In an environment that has Corset, `julia -m Corset` runs the same command.

## A first check

Write a script with two problems:

```julia
samples = [1.0, NaN, 3.0]
valid = filter(x -> x != NaN, samples)
try
    sum(valid)
catch
end
```

Check it:

```@setup first
using Corset
directory = mktempdir()
write(joinpath(directory, "demo.jl"), """
samples = [1.0, NaN, 3.0]
valid = filter(x -> x != NaN, samples)
try
    sum(valid)
catch
end
""")
```

```@example first
cd(() -> Corset.CLI.execute(["check", "demo.jl"], stdout, stdout; launch = false, cache = nothing), directory) # hide
```

The exit code is `1` because each finding has level `deny`. The [Guide](guide.md) tells how to set levels.

## Next

- [Guide](guide.md): project kind, levels, configuration, opt-out comments, baseline and fixes.
- [CLI](cli.md): commands, options and exit codes.
- [Rules](rules.md): each rule, with an example and the alternative.
