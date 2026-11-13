# runic: off
@show total
clock = ccall(:clock, Int32, ())
tmp = 1
tmp_buffer = zeros(3)
function foo(bar)
    return bar
end
struct Holder
    tmp::Int
end
for tmp_index in 1:3
    work(tmp_index)
end
