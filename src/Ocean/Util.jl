
module Util
  # Utility to allow match(re, str)[1]
  # TODO: Get this into Base.
  function ref(m::RegexMatch, i::Int64)
    return m.captures[i]
  end
  
  export ref
end
