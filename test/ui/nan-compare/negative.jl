# runic: off
missing_value(x) = isnan(x)
same(x) = isequal(x, NaN)
ordered(x) = isless(x, NaN)
shifted(x) = x + NaN
renamed(x) = x == NaN_value
field(x, config) = x == config.NaN
other_module(x) = x == Other.NaN
mapped() = map.(==, NaN)
keyword(x) = ==(x; atol = NaN)
called(x) = compare(x, NaN)
quoted = :(x == NaN)
