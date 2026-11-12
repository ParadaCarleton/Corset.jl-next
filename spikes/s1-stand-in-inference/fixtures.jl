# Differential fixtures: run with `julia --project=. fixtures.jl`.
include("src/S1.jl")
using .S1, .S1.StandIns, .S1.Scan, .S1.Signatures

module Fix
    mul_int(x::Integer) = x * 2                      # report: Int64 vs stand-in
    mul_half(x::Real) = x * 0.5                      # report through float case
    narrowed(x::AbstractFloat) = Float32(x * 0.5)    # intermediate only
    div_int(x::Integer) = x / 2                      # pass: Float64 either way
    mul_float(x::AbstractFloat) = x * 2              # pass: literal is weak already
    to_f64(x::AbstractFloat) = Float64(x)            # report: type name
    loop(x::Integer, n::Int) = (
        y = x + 1; for _ in 1:n
            y += x
        end; y
    )  # report through phi
    function acc(v::AbstractVector{<:Integer})       # report: `s = 0` accumulator
        s = 0
        for x in v
            s += x
        end
        return s
    end
    function acc_ok(v::AbstractVector{<:Integer})    # pass: zero(eltype)
        s = zero(eltype(v))
        for x in v
            s += x
        end
        return s
    end
    index(v::AbstractVector{<:Real}) = v[1] + v[2]   # pass: literal index
    const SCALE = 3
    scaled(x::Integer) = SCALE * x                   # report: constant
    store!(v::AbstractVector{<:Integer}, x::Integer) = (v[1] = x * 2; v)  # pass: store converts
    range_to(n::Integer) = 1:n                       # report: UnitRange{Int64}
end

mods = Set{Module}([Fix])
for m in sort(Signatures.package_methods(Fix), by = m -> m.line)
    sigs, _ = Signatures.stand_in_signatures(m, mods)
    for tt in sigs
        r = Scan.infer_method(m, tt)
        r isa Symbol && (println(m.name, " skip ", r); continue)
        ir, rt = r
        for s in Scan.literal_sites(ir)
            println(
                rpad(string(m.name), 10), rpad(string(tt.parameters[2:end]), 40), " ", s.kind, " ", s.callee, "(", s.literal,
                ") ", s.escape, "  ", s.original, " vs ", s.counterfactual
            )
        end
    end
end
