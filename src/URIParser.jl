__precompile__()

module URIParser

export URI
export defrag, userinfo, path_params, query_params, isvalid
export escape, escape_form, escape_with, unescape, unescape_form

import Base: isequal, isvalid, show, print, (==)
using Compat
import Compat.String

include("parser.jl")
include("esc.jl")
include("utils.jl")
include("precompile.jl")
_precompile_()

end # module
