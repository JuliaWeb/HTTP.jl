isdefined(Base, :__precompile__) && __precompile__()

module URIParser

using Compat
using HttpCommon

import HttpCommon: URI

export URI
export defrag, userinfo, path_params, query_params, isvalid
export escape, escape_form, escape_with, unescape, unescape_form

import Base: isequal, isvalid, show, print, (==)

include("parser.jl")
include("esc.jl")
include("utils.jl")

end # module
