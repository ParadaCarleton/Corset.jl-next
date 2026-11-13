# runic: off
# Name regex must match whole name.
attempt = 1
food = 2
my_tmp = 3
# Names in use, not bound, pass.
work(tmp)
# Pattern matches macro and call as written.
@info "tmp" total
show(stdout, total)
call = :ccall

# Anonymous parameter binds no name.
convert_tmp(::Int) = 1
