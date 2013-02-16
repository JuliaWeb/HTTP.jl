require("HTTP")
require("HTTP/src/BasicServer")

require("Calendar")

module Ocean
  # """
  # Fertilizer
  # I'll take bullshit if that's all you got
  # Some fertilizer
  # Fertilizer
  # Ooooooo
  # """
  
  import Base.abspath, Base.joinpath, Base.dirname
  import HTTP
  
  export
    # App construction
    new_app,
    # Request methods
    get,
    post,
    put,
    delete,
    any,
    route,
    # Utilities for interacting with HTTP server API
    binding,
    call
  
  include("Ocean/Util.jl")
  using Util
  
  type Route
    method::String
    path::Union(String, Regex)
    opts::Dict{Any,Any}
    handler::Function
  end
  
  type App
    routes::Array{Route}
    source_dir::String
    source_path::String
    
    App() = new(Route[], "", "")
  end
  
  # Used in Extra
  const _blank_request = HTTP.Request()
  const _blank_response = HTTP.Response()
  const _blank_app = App()
  # const _blank_func = function(); end
  const _blank_func_1 = function(a); end
  # const _blank_func_2 = function(a, b); end
  # Extra stuff that goes along with the req-rep pair for route calling.
  type Extra
    params::Union(Array, Bool)
    app::App
    req::HTTP.Request
    res::HTTP.Response
    file::Function
    
    Extra(app::App, req::HTTP.Request, res::HTTP.Response) = new(
      false,
      app,
      req,
      res,
      _blank_func_1
    )
    
    Extra() = new(_blank_app, _blank_request, _blank_response)
  end
  
  function app()
    _app = App()
    
    tls = task_local_storage()
    sp = Base.get(tls, :SOURCE_PATH, nothing)
    # If sp is nothing then it's coming from the REPL and we'll just use
    # the pwd.
    # If it's a string then it's the path to the source file that originally
    # loaded everything.
    _app.source_dir  = (sp == nothing) ? pwd() : dirname(sp)
    _app.source_path = (sp == nothing) ? "(repl)" : sp
    
    return _app
  end
  # Alias for when the module is imported
  new_app = app
  
  # Utilities for working within the app
  function file(app::App, path::String)
    if begins_with(path, "/")
      p = path
    else
      p = app.source_dir*"/"*path
    end
    r = open(readall, p, "r")
    return r
  end
  
  function route(app::App, _route::Route)
    push!(app.routes, _route)
  end
  function route(app::App, method::String, path::Any, opts::Dict{Any,Any}, handler::Function)
    route(app, Route(method, path, opts, handler))
  end
  # Shortcuts for creating routes.
  function get(app::App, path::Any, handler::Function)
    route(app, Route("GET", path, Dict{Any,Any}(), handler))
  end
  function post(app::App, path::Any, handler::Function)
    route(app, Route("POST", path, Dict{Any,Any}(), handler))
  end
  function put(app::App, path::Any, handler::Function)
    route(app, Route("PUT", path, Dict{Any,Any}(), handler))
  end
  function delete(app::App, path::Any, handler::Function)
    route(app, Route("DELETE", path, Dict{Any,Any}(), handler))
  end
  function any(app::App, path::Any, handler::Function)
    # TODO: Make a special "ANY" method?
    # for method in ["GET", "POST", "PUT", "DELETE"]
      route(app, Route("ANY", path, Dict{Any,Any}(), handler))
    # end
  end
  
  function new_extra(app, req, res)
    extra = Extra(app, req, res)
    extra.file = Util.enscopen(app, file)
    return extra
  end
  
  function route_path_matches(rp::Regex, path::String, extra::Extra)
    match = Base.match(rp, path)
    if match == nothing
      return false
    else
      extra.params = match.captures
      return true
    end
  end
  function route_path_matches(rp::String, path::String, extra::Extra)
    return rp == path
  end
  
  function route_method_matches(route_method::String, req_method::String)
    return route_method == req_method || route_method == "ANY"
  end
  
  function call_request(app, req, res)
    extra = new_extra(app, req, res)
    for _route in app.routes
      # Do the simple comparison first
      if route_method_matches(_route.method, req.method)
        path_match = route_path_matches(_route.path, req.path, extra)
        if path_match
          ret = _route.handler(req, res, extra)
          if ret != false
            return ret
          end
        end
      end
    end
    
    return false
  end
  
  # Interface with HTTP
  function call(app, req, res)
    ret = call_request(app, req, res)
    if isa(ret, String)
      res.body = ret
      return true
    elseif ret == false
      # TODO: Set up system for not found errors and such
      # return [404, "Not found"]
      return false
    # Returning true (or nothing) will assume response data has been set in
    # res.body.
    # Assume nothing return (no return) to mean successful route call.
    elseif ret == true || ret == nothing
      return true
    else
      error("Unexpected response format '"*string(typeof(ret))*"'")
    end
  end
  # Creates a function closure function for HTTP to call with the app.
  function binding(app::App)
    return function(req, res)
      call(app, req, res)
    end
  end
  
end
