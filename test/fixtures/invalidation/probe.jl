# Print each Corset method instance that loading file ARGS[1] invalidates; then count of all invalidated instances.
using Corset: Corset
using SnoopCompileCore: @snoop_invalidations

invalidations = @snoop_invalidations include(ARGS[1])
instances = unique(entry for entry in [invalidations.logedges; invalidations.logmeths] if entry isa Core.MethodInstance)
foreach(println, (instance for instance in instances if instance.def isa Method && Base.moduleroot(instance.def.module) === Corset))
println(length(instances))
