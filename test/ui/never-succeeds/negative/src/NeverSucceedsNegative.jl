# runic: off
module NeverSucceedsNegative

checked(count::Integer) = count >= 0 ? count : error("negative count")
fail(count::Integer) = throw(ArgumentError("count $count"))
wrapped(count::Integer) = fail(count)

# Method for model type `Float32` only: stand-in fails, model succeeds; coverage line counts it.
single(value::Float32) = value / 2
halved(value::AbstractFloat) = single(value)

double(count::Integer) = 2count

# Base case ends recursion; loop whose call can throw may end by throwing.
countdown(count::Int) = count > 0 ? countdown(count - 1) : 0
pump(channel::Channel{Int}) = (while true; put!(channel, 1); end)

end
