"""
Stage times of one run, which `--timings` prints: wall, compile and garbage collection seconds per stage.
"""
module Timings

using Printf: @sprintf

"""Wall, compile and garbage collection seconds of `stage`."""
struct Timing
    stage::String
    seconds::Float64
    compile::Float64
    gc::Float64
end

"""Timing of `stage` from `@timed` result `result`."""
timing(stage::String, result::NamedTuple)::Timing = Timing(stage, result.time, result.compile_time, result.gctime)

"""Value of `work()`; appends its timing under `stage` to `timings` unless `nothing`."""
function timed!(work::Function, timings::Union{Nothing, AbstractVector{Timing}}, stage::String)::Any
    isnothing(timings) && return work()
    result = @timed work()
    push!(timings, timing(stage, result))
    return result.value
end

"""Print `timings` to `io`: header, then one line per stage with its seconds to the millisecond."""
function print_timings(io::IO, timings::AbstractVector{Timing})::Nothing
    println(io, "corset: timings in seconds (wall, compile, garbage collection)")
    width = maximum(timing -> textwidth(timing.stage), timings; init = 0)
    for timing in timings
        println(io, "  ", rpad(timing.stage, width), @sprintf("%10.3f%10.3f%10.3f", timing.seconds, timing.compile, timing.gc))
    end
    return nothing
end

end
