require("Calendar")
require("OpenSSL")
require("JSON")

import Calendar
import OpenSSL
import JSON

const COOKIE_SESSION_DEFAULTS = Dict{Symbol,Any}()
COOKIE_SESSION_DEFAULTS[:secret] = "DANGER"
COOKIE_SESSION_DEFAULTS[:digest] = "SHA256"
COOKIE_SESSION_DEFAULTS[:key] = "julia.http.session"
COOKIE_SESSION_DEFAULTS[:domain] = nothing
COOKIE_SESSION_DEFAULTS[:path] = "/"
COOKIE_SESSION_DEFAULTS[:secure] = false
COOKIE_SESSION_DEFAULTS[:httponly] = true
# AbstractCalendarDuration or CalendarTime
COOKIE_SESSION_DEFAULTS[:expires] = Calendar.weeks(1)

typealias CookieSession Dict{String,Any}

function cookie_session(app::Function, _config::Dict)
  config = merge(COOKIE_SESSION_DEFAULTS, _config)
  if config[:secret] == "DANGER"
    println("You should set the :secret in your cookie_session middleware!")
  end
  
  # NOTES:
  # Sets env[:session] to a CookieSession (Dict{String,Any}) that is then
  # JSON'ed with a hash of it and the secret.
  
  function unpack_session(s::String)
    #return JSON.parse(s)
    hash, data = split(s, ':', 2)
    
    hash_check = OpenSSL.Digest.digest(config[:digest], config[:secret]*":"*data)
    if hash_check == hash
      ret = JSON.parse(data)
      if typeof(ret) != Dict{String,Any}
        # Maybe have it be error()?
        println("Unexpected cookie data type: "*string(typeof(ret)))
        # Right now if we don't get what we wanted we'll just print an error
        # and dump a fresh dict.
        return Dict()
      end
      return ret
    else
      # If the hash check didn't pan out then reset the session data.
      return Dict()
    end
  end
  function pack_session(cs::Dict)
    data = JSON.to_json(cs)
    hash = OpenSSL.Digest.digest(config[:digest], config[:secret]*":"*data)
    return hash*":"*data
  end
  
  
  function before(req::HTTP.Request, res::HTTP.Response)
    if has(req.cookies, config[:key])
      req.env[:session] = unpack_session(req.cookies[config[:key]][1])
      # Maintain copy of session before app runs to know if we need to update
      # the cookie or not.
      req.env[:original_session] = deepcopy(req.env[:session])
    else
      req.env[:session] = CookieSession()
      # New so always update the cookie.
      req.env[:original_session] = nothing
    end
  end
  
  function after(req::HTTP.Request, res::HTTP.Response)
    # If the session data has changed then generate a new session cookie.
    if req.env[:session] != req.env[:original_session]
      c = HTTP.new_cookie(config[:key], pack_session(req.env[:session]))
      if config[:domain] != false && config[:domain] != nothing
        c.domain = config[:domain]
      end
      c.path = config[:path]
      if isa(config[:expires], Calendar.AbstractCalendarDuration)
        c.expires = Calendar.now() + config[:expires]
      elseif isa(config[:expires], Calendar.CalendarTime)
        c.expires = config[:expires]
      else
        error("Unrecognized expires type: "*string(typeof(config[:expires])))
      end
      c.secure = config[:secure]
      c.httponly = config[:httponly]
      
      HTTP.set_cookie(res, c)
    end
  end
  
  return function(req, res)
    before(req, res)
    ret = app(req, res)
    after(req, res)
    return ret
  end
  
end
