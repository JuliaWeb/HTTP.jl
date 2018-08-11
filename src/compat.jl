using Base64
import Dates

const bytesavailable = Base.bytesavailable
const compat_findfirst = Base.findfirst
const compat_replace = Base.replace
const compat_occursin = Base.occursin
const compat_parse = Base.parse
const compat_string = Base.string

compat_stdout() = stdout

compat_search(s::AbstractString, c::Char) = Base.findfirst(isequal(c), s)
using Sockets

sprintcompact(x) = sprint(show, x; context=:compact => true)

