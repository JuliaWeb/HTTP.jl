module URIParser

export URI
export defrag, userinfo, path_params, isvalid
export escape, escape_form, escape_with, unescape, unescape_form

import Base.isequal, Base.isvalid
import Base: show, print

include("parser.jl")
include("esc.jl")
include("utils.jl")

end # module