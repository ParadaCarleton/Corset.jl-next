# runic: off
missing_value(x) = x == NaN
present(x) = x != NaN
also_present(x) = x ≠ Base.NaN32
flipped(x) = NaN64 == x
both() = NaN == NaN
masked(xs) = xs .== NaN
kept(xs) = xs .!= NaN16
below(x) = x < NaN
at_most(x) = x <= NaN
above(x) = NaN ≥ x
same_bits(x) = x === NaN
other_bits(x) = x !== NaN
identical(x) = x ≡ NaN
dotted_bits(xs) = xs .=== NaN
in_range(low, x) = low < x == NaN
dotted_chain(xs, high) = xs .< NaN .< high
count_missing(xs) = count(==(NaN), xs)
drop_missing(xs) = filter(!=(NaN), xs)
prefix(x) = ==(x, NaN)
@test (x + 1) == NaN
assigned(state) = (state.count = 0) .!= NaN16
