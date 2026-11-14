trace_of(matrix::Matrix{Float64}) = tr(matrix)
label(value::Float64) = @sprintf("%.2f", value)
roundtrip(text::String) = String(base64decode(base64encode(text)))
note() = md"*string macro*"
