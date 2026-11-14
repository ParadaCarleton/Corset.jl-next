# runic: off
"""Package without public names; its narrow annotations meet no outside caller."""
module OverspecifiedTypePrivate

"""Scaled copy of values."""
scale(values::Vector{Float64}, factor::Float64) = values .* factor

end
