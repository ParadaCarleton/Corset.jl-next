# runic: off
# `baremodule` lacks implicit `using Base`: `using` can supply `UnitRange` that loop resizes, so fix is manual.
baremodule Spans
using Base: push!, *
using Ranges
function doubled(span::UnitRange{Int})
    out = Int[]
    for i in span
        push!(out, 2i)
    end
    return out
end
end
