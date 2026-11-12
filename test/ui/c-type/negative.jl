# runic: off
checksum(data) = ccall((:crc32, libz), Cuint, (Cuint, Ptr{UInt8}, Cuint), 0, data, length(data))
length_of(s) = @ccall strlen(s::Cstring)::Csize_t
buffer = Ref{Cint}(0)
slot::Ptr{Cdouble} = C_NULL
width::UInt32 = 0
