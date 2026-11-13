# runic: off
missing_value(x) = isnan(x)
present(x) = !isnan(x)
also_present(x) = !isnan(x)
flipped(x) = isnan(x)
both() = isnan(NaN)
masked(xs) = isnan.(xs)
kept(xs) = .!isnan.(xs)
below(x) = x < NaN
at_most(x) = x <= NaN
above(x) = NaN ≥ x
same_bits(x) = x === NaN
other_bits(x) = x !== NaN
identical(x) = x ≡ NaN
dotted_bits(xs) = xs .=== NaN
in_range(low, x) = low < x == NaN
dotted_chain(xs, high) = xs .< NaN .< high
count_missing(xs) = count(isnan, xs)
drop_missing(xs) = filter(!isnan, xs)
prefix(x) = isnan(x)
@test isnan((x + 1))
assigned(state) = (state.count = 0) .!= NaN16
