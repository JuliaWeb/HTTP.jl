__precompile__()

module URIParser

export URI
export defrag, userinfo, path_params, query_params, isvalid
export escape, escape_form, escape_with, unescape, unescape_form

using Lazy

import Base: isequal, isvalid, show, print, (==)

include("parser.jl")
include("esc.jl")
include("utils.jl")
include("precompile.jl")
_precompile_()

end # module
