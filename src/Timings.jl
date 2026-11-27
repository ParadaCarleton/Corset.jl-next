"""
Stage times of one run, which `--timings` prints as each stage ends: wall, compile and garbage collection seconds per
stage.
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

"""Stream that `--timings` prints to. One concrete type for every stream, so stage functions compile once."""
struct Sink
    io::IO
end

"""Width of stage name column: longest stage name, `method store update`, and one space."""
const STAGE_WIDTH = 20

"""Print `timing` to `sink` as one line: stage, then wall, compile and garbage collection seconds to the millisecond."""
function print_timing(sink::Sink, timing::Timing)::Nothing
    seconds = @sprintf("%10.3f s wall%10.3f s compile%10.3f s gc", timing.seconds, timing.compile, timing.gc)
    println(sink.io, "corset: stage ", rpad(timing.stage, STAGE_WIDTH), seconds)
    return nothing
end

"""Value of `work()`; prints its timing under `stage` to `sink` unless `nothing` (`print_timing`)."""
function timed(work::Function, sink::Union{Nothing, Sink}, stage::String)::Any
    isnothing(sink) && return work()
    result = @timed work()
    print_timing(sink, timing(stage, result))
    return result.value
end

end
