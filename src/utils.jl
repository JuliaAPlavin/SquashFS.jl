import CBinding: Cstruct


@generated function read_bittypes(io::IO, ::Type{T}) where T
    ftypes = fieldnames(T) .=> fieldtypes(T)
    pred = typ -> isbitstype(typ) || typ <: Cstruct
    bitfs = Iterators.takewhile(((k, typ),) -> pred(typ), ftypes)
    nonbitfs = Iterators.dropwhile(((k, typ),) -> pred(typ), ftypes)
    assignments = [:($k = read(io, $typ)) for (k, typ) in bitfs]
    return :($T(;$(assignments...)))
end

function read_all(s::IO, nb::Integer)
    res = read(s, nb)
    length(res) < nb && throw(EOFError())
    return res
end
