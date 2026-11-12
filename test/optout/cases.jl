# runic: off
# corset: allow-file untyped-empty -- fixture builds untyped containers on purpose
items = []
lookup = Dict()
exact(total) = total ≈ 0  # corset: allow approx-zero -- exact zero intended
# corset: allow approx-zero -- whole function covered
function near(value)
    return value ≈ 0
end
far(value) = value ≈ 0
count_one = 1  # corset: allow c-type -- nothing to suppress
count_two = 2  # corset: allow approx-zero
count_three = 3  # corset: allow no-such-rule -- typo
# corset: allowed approx-zero -- malformed
# corset: allow-file juxtaposition -- too late
