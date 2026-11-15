# runic: off
module NeverSucceedsNegative

checked(count::Integer) = count >= 0 ? count : error("negative count")
fail(count::Integer) = throw(ArgumentError("count $count"))
wrapped(count::Integer) = fail(count)

# Method for model type `Float32` only: stand-in fails, model succeeds; coverage line counts it.
single(value::Float32) = value / 2
halved(value::AbstractFloat) = single(value)

double(count::Integer) = 2count

end
