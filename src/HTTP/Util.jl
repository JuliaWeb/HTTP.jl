module Util
  
  import HTTP
  
  function wrap_app(app::Function, req::HTTP.Request, res::HTTP.Response)
    ret = app(req, res)
    if isequal(ret, nothing)
      error("App returned nothing")
    else
      # Legacy handling.
      if isa(ret, Array)
        res.status = ret[1]
        res.body = string(ret[2])
        return true
      elseif isa(ret, String)
        res.body = ret
        return true
      
      # Ideally apps will eventually update the response themselves and just
      # return a bool of whether or not they ran. Currently Ocean conforms to
      # this.
      elseif ret == true || ret == false
        return ret
      else
        error("Unexpected response format '"*string(typeof(ret))*"' from app function")
      end
    end
    return false
  end
  
  # Function version of @opt.
  function opt(srcdict::Dict, desttype, key::Union(String, Symbol))
    key_str = string(key)
    key_sym = symbol(key)
    if has(srcdict, key_str)
      desttype.(key_sym) = srcdict[key_str]
    end
    if has(srcdict, key_sym)
      desttype.(key_sym) = srcdict[key_sym]
    end
  end
  # Copies options (specified in keys) from dict (srcdict) into desttype.
  # Example:
  #   type MyType
  #     member1
  #     member2
  #   end
  #   mytypeinstance = MyType(1, 2)
  #   mydict = {
  #     "member1" => 3,
  #     :member2  => 4
  #   }
  #   opts(mydict, mytypeinstance, [:member1, "member2"])
  #   @assert mytypeinstance.member1 == 3
  #   @assert mytypeinstance.member2 == 4
  function opts(srcdict::Dict, desttype, keys::Array)
    for key in keys
      opt(srcdict, desttype, key)
    end
  end
    
  # ESCAPING
  # Unescaping
  escaped_regex = r"%([0-9a-fA-F]{2})"
  function unescape(str)
    # def _unescape(str, regex) str.gsub(regex){ $1.hex.chr } end
    for m in each_match(escaped_regex, str)
      for capture in m.captures
        rep = string(char(parseint(capture, 16)))
        str = replace(str, "%"*capture, rep)
      end
    end
    return str
  end
  function unescape_form(str)
    str = replace(str, "+", " ")
    return unescape(str)
  end
  # Escaping
  control_array = convert(
    Array{Uint8,1},
    [i for i = 0:parseint("1f",16)]
  )
  control = utf8(ascii(control_array)*"\x7f")
  space = utf8(" ")
  delims = utf8("%<>\"")
  unwise   = utf8("{}|\\^`")
  nonascii_array = convert(
    Array{Uint8,1},
    [i for i=parseint("80", 16):(parseint("ff", 16))]
  )
  #nonascii = utf8(string(nonascii_array))
  reserved = utf8(",;/?:@&=+\$![]'*#")
  # Strings to be escaped
  # (Delims goes first so '%' gets escaped first.)
  unescaped = delims * reserved * control * space * unwise# * nonascii
  unescaped_form = delims * reserved * control * unwise# * nonascii
  # Escapes chars (in second string); also escapes all non-ASCII chars.
  function escape_with(str, use)
    chars = split(use, "")
      
    for c in chars
      _char = c[1] # Character string as Char
      h = hex(int(_char))
      if length(h) < 2
        h = "0"*h
      end
      str = replace(str, c, "%" * h)
    end
      
    for i in nonascii_array
      str = replace(str, char(i), "%" * hex(i))
    end
      
    return str
  end
    
  function escape(str)
    return escape_with(str, unescaped)
  end
  function escape_form(str)
    str = escape_with(str, unescaped_form)
    return replace(str, " ", "+")
  end
    
  export escape, escape_form, unescape, unescape_form, @opt, opt, opts
    
end#module Util
