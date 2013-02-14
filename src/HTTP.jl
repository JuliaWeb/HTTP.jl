# HTTP.jl
# Authors: Dirk Gadsden

require("Calendar")

module HTTP
  
  type Request
    method::String
    path::String
    query_string::String
    headers::Dict{String,Any}
    cookies::Dict{String,Any}
    version::String
    raw_data::String
    data::Any
  end
  Request() = Request("", "", "", Dict{String,Any}(), Dict{String,Any}(), "", "", Dict{String,Any}())
  
  type Cookie
    key::String
    value::String
    domain::String
    path::String
    expires::String
    secure::Bool
    httponly::Bool
  end
  Cookie(_key::String, _value::String) = Cookie(
    _key,
    _value,
    "",
    "",
    "",
    false,
    false
  )
  
  
  
  module Util
    # DEPRECATED (See function versions below.)
    # Allows for assigning hash keys from dict to members in a type.
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
    #   @opt mydict mytypeinstance :member1
    #   @opt mydict mytypeinstance "member2"
    #   @assert mytypeinstance.member1 == 3
    #   @assert mytypeinstance.member2 == 4
    macro opt(srcdict, desttype, key)
      # Doing `@opt a b :c` makes key be a QuoteNode.
      if typeof(key) == QuoteNode
        # a = ":test"; a[2:end] = "test"
        key = string(key)[2:end]
      end
      key_string = string(key)
      key_symbol = symbol(key)
    
      quote_key_symbol = expr(:quote, {key_symbol})
      type_member_expr = expr(:., {esc(desttype), quote_key_symbol})
      # type_member_expr = :(type.member)
      #   Where type is desttype and member is key.
      quote
        if has($(esc(srcdict)), $key_string)
          $(type_member_expr) = $(esc(srcdict))[$key_string]
        end
        if has($(esc(srcdict)), $quote_key_symbol)
          $(type_member_expr) = $(esc(srcdict))[$quote_key_symbol]
        end
      end
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
  end
  
  function new_cookie(key::String, value::String, opts::Dict{Any,Any})
    cookie = Cookie(key, value)
    # Util.@opt opts cookie :domain
    # Util.opt(opts, cookie, :domain)
    Util.opts(opts, cookie, [:domain, :path, :expires, :secure, :httponly])
    return cookie
  end
  new_cookie(key::String, value::String) = new_cookie(key, value, Dict{String,Any}())
  
  type Response
    status::Integer
    body::String
    headers::Dict{String,Any}
    cookies::Array{Cookie,1}
  end
  Response(status::Integer, body::String) = Response(status, body, Dict{String,Any}(), Cookie[])
  Response() = Response(200, "")
  
  function set_cookie(resp::Response, cookie::Cookie)
    push!(resp.cookies, cookie)
  end
  
  export Request, Response, @opt
end
