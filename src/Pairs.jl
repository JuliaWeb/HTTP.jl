module Pairs

export defaultbyfirst, setbyfirst, getbyfirst, setkv, getkv, rmkv

"""
    setbyfirst(collection, item) -> item

Set `item` in a `collection`.
If `first() of an exisiting item matches `first(item)` it is replaced.
Otherwise the new `item` is inserted at the end of the `collection`.
"""
function setbyfirst(c, item, eq = ==)
    k = first(item)
    i = findfirst(x->eq(first(x), k), c)
    if i === nothing
        push!(c, item)
    else
        c[i] = item
    end
    return item
end

"""
    getbyfirst(collection, key [, default]) -> item

Get `item` from collection where `first(item)` matches `key`.
"""
function getbyfirst(c, k, default=nothing, eq = ==)
    i = findfirst(x->eq(first(x), k), c)
    return i === nothing ? default : c[i]
end

"""
    defaultbyfirst(collection, item)

If `first(item)` does not match match `first()` of any existing items,
insert the new `item` at the end of the `collection`.
"""
function defaultbyfirst(c, item, eq = ==)
    k = first(item)
    if findfirst(x->eq(first(x), k), c) === nothing
        push!(c, item)
    end
    return
end

"""
    setkv(collection, key, value)

Set `value` for `key` in collection of key/value `Pairs`.
"""
setkv(c, k, v) = setbyfirst(c, k => v)

"""
    getkv(collection, key [, default]) -> value

Get `value` for `key` in collection of key/value `Pairs`,
where `first(item) == key` and `value = item[2]`
"""
function getkv(c, k, default=nothing)
    i = findfirst(x->first(x) == k, c)
    return i === nothing ? default : c[i][2]
end

"""
    rmkv(collection, key)

Remove `key` from `collection` of key/value `Pairs`.
"""
function rmkv(c, k, eq = ==)
    i = findfirst(x->eq(first(x), k), c)
    if !(i === nothing)
        deleteat!(c, i)
    end
    return
end

end # module Pairs
