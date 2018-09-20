"""
Execute a regular expression without the overhead of `Base.Regex`
"""
exec(re::Regex, bytes, offset::Int=1) =
    Base.PCRE.exec(re.regex, bytes, offset-1, re.match_options, re.match_data)


"""
`SubString` containing the bytes following the matched regular expression.
"""
nextbytes(re::Regex, bytes) = SubString(bytes, re.ovec[2]+1)


"""
`SubString` containing a regular expression match group.
"""
group(i, re::Regex, bytes) = SubString(bytes, re.ovec[2i+1]+1,
                                              prevind(bytes, re.ovec[2i+2]+1))

group(i, re::Regex, bytes, default) =
    re.ovec[2i+1] == Base.PCRE.UNSET ?
    default :
    SubString(bytes, re.ovec[2i+1]+1, prevind(bytes, re.ovec[2i+2]+1))
