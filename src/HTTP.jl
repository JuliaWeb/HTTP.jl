# HTTP.jl
# Authors: Dirk Gadsden

require("Calendar")

module HTTP
  
  import Calendar
  
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
  Request() = Request(
    "", "", "",
    Dict{String,Any}(), Dict{String,Any}(),
    "", "",
    Dict{String,Any}()
  )
  
  type Cookie
    key::String
    value::String
    domain::String
    path::String
    expires::Union(String, Calendar.CalendarTime)
    secure::Bool
    httponly::Bool
  end
  Cookie(_key::String, _value::String) = Cookie(
    _key,
    _value,
    "",#domain
    "",#path
    "",#expires
    false,#secure
    false#httponly
  )
  
  type Response
    status::Integer
    body::String
    headers::Dict{String,Any}
    cookies::Array{Cookie,1}
  end
  Response(status::Integer, body::String) = Response(status, body, Dict{String,Any}(), Cookie[])
  Response() = Response(200, "")
  
  include("HTTP/Util.jl")
  
  # Utility function for more easily creating HTTP.Cookie objects.
  function new_cookie(key::String, value::String, opts::Dict{Any,Any})
    cookie = Cookie(key, value)
    # Util.opt(opts, cookie, :domain)
    Util.opts(opts, cookie, [:domain, :path, :expires, :secure, :httponly])
    return cookie
  end
  # Use default options.
  new_cookie(key::String, value::String) = new_cookie(key, value, Dict{Any,Any}())
  
  # TODO: Maybe rewrite this to shove it straight onto
  #       resp.headers["Set-Cookie"] instead of the resp.cookies array.
  #       (Especially considering req.cookies and resp.cookies aren't even the
  #       same type (Dict vs Array).)
  function set_cookie(resp::Response, cookie::Cookie)
    push!(resp.cookies, cookie)
  end
  
  function ensure_rfc1123(v::String)
    return v
  end
  function ensure_rfc1123(v::Calendar.CalendarTime)
    vgmt = Calendar.tz(v, "GMT") # ensure GMT
    # format: Wdy, DD Mon YYYY HH:MM:SS GMT
    return Calendar.format("EEE, dd MMM yyyy HH:mm:ss zzz", vgmt)
  end
  
  # Add Calendar.CalendarTime method to Base's isempty method.
  import Base.isempty
  function isempty(c::Calendar.CalendarTime)
    return false
  end
  
  function cookie_header(c::Cookie)
    r = "Set-Cookie: "*c.key*"="*Util.escape(c.value)
    if !isempty(c.domain)
      r *= "; domain=" * c.domain
    end
    if !isempty(c.path)
      r *= "; path=" * c.path
    end
    if !isempty(c.expires)
      r *= "; expires=" * ensure_rfc1123(c.expires)
    end
    if c.httponly
      r *= "; HttpOnly"
    end
    if c.secure
      r *= "; secure"
    end
    return r
  end
  
  export Request, Response
end
