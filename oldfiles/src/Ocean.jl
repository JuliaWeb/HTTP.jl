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
    # Parameterized routes like "/object/:id"
    param_route,
    pr, # Shorthand for param_route
    @pr_str, # Macro for doing: pr"/object/:id"
    # Utilities for interacting with HTTP server API
    binding,
    call
  
  include("Ocean/Util.jl")

  type ParamRoute
    path::Regex
    names::Array{String,1}
    
    ParamRoute(path::Regex, names::Array{UTF8String,1}) = new(path, names)
    ParamRoute() = new(r"", String[])
  end
  
  type Route
    method::String
    path::Union(String, Regex, ParamRoute)
    opts::Dict{Any,Any}
    handler::Function
  end
  
  type App
    routes::Array{Route}
    source_dir::String
    source_path::String
    # NOTE: Keys that are symbols starting with "_" (eg. "_file") are reserved
    #       by Ocean.
    cache::ObjectIdDict
    
    App() = new(Route[], "", "", ObjectIdDict())
  end
  
  # Used in Extra
  const _blank_request = HTTP.Request()
  const _blank_response = HTTP.Response()
  const _blank_app = App()
  # const _blank_func = function(); end
  const _blank_func_1 = function(a); end
  # const _blank_func_2 = function(a, b); end
  const _blank_func_3 = function(a, b, c); end
  # Extra stuff that goes along with the req-rep pair for route calling.
  type Extra
    params::Union(Array, Dict, Bool)
    app::App
    req::HTTP.Request
    res::HTTP.Response
    file::Function
    template::Function
    redirect::Function
    
    Extra(app::App, req::HTTP.Request, res::HTTP.Response) = new(
      false,
      app,
      req,
      res,
      _blank_func_1, # file
      _blank_func_3, # template
      _blank_func_1 # redirect
    )
    
    Extra() = new(_blank_app, _blank_request, _blank_response)
  end
  
  include("Ocean/Template.jl")
  
  function app()
    _app = App()
    
    #tls = task_local_storage()
    #sp = Base.get(tls, :SOURCE_PATH, nothing)
    sp = Base.source_path()
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
  function file(app::App, path::String, do_cache::Bool)
    if beginswith(path, "/")
      p = path
    else
      p = app.source_dir*"/"*path
    end
    if do_cache
      sp = symbol("_file:" * p)
      if has(app.cache, sp)
        return app.cache[sp]
      end
    end
    r = open(readall, p, "r")
    if do_cache; app.cache[sp] = r; end
    return r
  end
  file(app::App, path::String) = file(app, path, true)
  
  function template(extra::Extra, format::Symbol, path::String, data::Any)
    app::App = extra.app
    if format == :ejl
      _template = memo(app.cache, "_ejl:$path") do
        contents = extra.file(path)
        __template, perf = Template.compile(contents)
        return __template
      end
      output, perf = Template.run(_template, data)
      return output
    elseif format == :mustache
      if Main.isdefined(:Mustache)
        _template = memo(app.cache, "_mustache:$path") do
          contents = extra.file(path)
          return Main.Mustache.parse(contents)
        end
        return Main.Mustache.render(_template, data)
      else
        error("Please install and require the Mustache package")
      end#Main.isdefined(:Mustache)
    else
      error("Unrecognized template format " * repr(format))
    end
  end
  template(extra::Extra, format::Symbol, path::String) = 
    template(extra, format, path, Dict())
  
  function new_extra(app::App, req::HTTP.Request, res::HTTP.Response)
    extra = Extra(app, req, res)
    extra.file = Util.enscopen(app, file)
    extra.template = Util.enscopen(extra, template)
    extra.redirect = Util.enscopen(res, Util.redirect)
    return extra
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
  
  const _separators = "[^/.?]"
  const _param_route_matcher = r":(\w+)"
  function param_route(s::String)
    names = UTF8String[]
    route = "^" * s * "\$"
    
    for m in eachmatch(_param_route_matcher, s)
      capture = m.captures[1]
      if in(capture, names)
        error("Param $(m.match) already in use")
      end
      push!(names, capture)
      
      _replace = "(" * _separators * "+)"
      route = replace(route, m.match, _replace)
    end
    
    return ParamRoute(Regex(route), names)
  end
  pr = param_route
  
  macro pr_str(s)
    return param_route(s)
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
  function route_path_matches(rp::ParamRoute, path::String, extra::Extra)
    match = Base.match(rp.path, path)
    if match == nothing
      return false
    else
      params = Dict{String,String}()
      i = 1
      for name in rp.names
        params[name] = match.captures[i]
        i += 1
      end
      extra.params = params
      return true
    end
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
