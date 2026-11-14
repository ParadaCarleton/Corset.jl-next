using Unicode: normalize
shout(text::String) = uppercase(text)
letters(text::String) = collect(graphemes(text))
