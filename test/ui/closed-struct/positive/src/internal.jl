# runic: off
"""Private module: its exports, as `Model`, are private too."""
module Internal

export Model

# Struct holds byte 210, like public `Model`.
"""Private model."""
struct Model
    bias::Float64
    scale::Float64
    offset::Float64
end

end
