
module Util
  # Utility to allow match(re, str)[1]
  import Base.ref
  function ref(m::RegexMatch, i::Int64)
    return m.captures[i]
  end
  
  function get_single(dict::Dict{String,Any}, param::String)
    if has(dict, param)
      val = dict[param]
      if isa(val, Array)
        return val[1]
      else
        return val
      end
    else
      return false
    end
  end
  gs = get_single
  
  # TODO: Maybe this can be refactored into a prettier macro?
  #       (Too late at night to figure out macroing this right now.)
  # Example:
  #   function scope_me(scope::ScopeThingy, b, c)
  #     return scope.a+b+c
  #   end
  #   scoped = enscopen(scope_thingy, scope_me)
  #   party = scoped(b, c)
  function enscopen(scope::Any, func::Function)
    return function(args...)
      return func(scope, args...)
    end
  end
  
  export ref, gs, get_single
end
