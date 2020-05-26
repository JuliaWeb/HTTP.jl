# we define our own RegexAndMatchData, similar to the definition in Base
# but we call create_match_data once in __init__
mutable struct RegexAndMatchData
    re::Regex
    match_data::Ptr{Cvoid}
    RegexAndMatchData(re::Regex) = new(re) # must create_match_data in __init__
end

function initialize!(re::RegexAndMatchData)
    re.match_data = Base.PCRE.create_match_data(re.re.regex)
    return
end

@static if isdefined(Base, :RegexAndMatchData)

"""
Execute a regular expression without the overhead of `Base.Regex`
"""
exec(re::RegexAndMatchData, bytes, offset::Int=1) =
    Base.PCRE.exec(re.re.regex, bytes, offset-1, re.re.match_options, re.match_data)

"""
`SubString` containing the bytes following the matched regular expression.
"""
nextbytes(re::RegexAndMatchData, bytes) = SubString(bytes, unsafe_load(Base.PCRE.ovec_ptr(re.match_data), 2) + 1)

"""
`SubString` containing a regular expression match group.
"""
function group(i, re::RegexAndMatchData, bytes)
    p = Base.PCRE.ovec_ptr(re.match_data)
    SubString(bytes, unsafe_load(p, 2i+1) + 1, prevind(bytes, unsafe_load(p, 2i+2) + 1))
end

function group(i, re::RegexAndMatchData, bytes, default)
    p = Base.PCRE.ovec_ptr(re.match_data)
    return unsafe_load(p, 2i+1) == Base.PCRE.UNSET ? default :
        SubString(bytes, unsafe_load(p, 2i+1) + 1, prevind(bytes, unsafe_load(p, 2i+2) + 1))
end

else # old Regex style

exec(re::RegexAndMatchData, bytes, offset::Int=1) = Base.PCRE.exec(re.re.regex, bytes, offset-1, re.re.match_options, re.re.match_data)
nextbytes(re::RegexAndMatchData, bytes) = SubString(bytes, re.re.ovec[2]+1)
group(i, re::RegexAndMatchData, bytes) = SubString(bytes, re.re.ovec[2i+1]+1, prevind(bytes, re.re.ovec[2i+2]+1))
group(i, re::RegexAndMatchData, bytes, default) = re.re.ovec[2i+1] == Base.PCRE.UNSET ? default : SubString(bytes, re.re.ovec[2i+1]+1, prevind(bytes, re.re.ovec[2i+2]+1))

end
