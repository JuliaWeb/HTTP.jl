abstract type Scheme end

struct http <: Scheme end
struct https <: Scheme end

const Headers = Dict{String, String}
