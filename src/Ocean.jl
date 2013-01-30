require("HTTP")
require("HTTP/src/BasicServer")

module Ocean
  # """
  # Fertilizer
  # I'll take bullshit if that's all you got
  # Some fertilizer
  # Fertilizer
  # Ooooooo
  # """
  
  type Route
    method::String
    path::Any
    opts::Dict{Any,Any}
    handler::Function
  end
  
  type App
    routes::Array{Route}
    
    App() = new(Route[])
  end
  
  function app()
    return App()
  end
  
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
    for method in ["GET", "POST", "PUT", "DELETE"]
      route(app, Route(method, path, Dict{Any,Any}(), handler))
    end
  end
  
  function route(app::App, method::String, path::Any, opts::Dict{Any,Any}, handler::Function)
    route(app, Route(method, path, opts, handler))
  end
  function route(app::App, _route::Route)
    push!(app.routes, _route)
  end
  
  function call(app, req, res)
    for _route in app.routes
      if _route.method == req.method && _route.path == req.path
        return _route.handler(req, res, nothing)
      end
    end
    
    return nothing
  end
  
  function binding(app::App)
    return function(req, res)
      call(app, req, res)
    end
  end
  
end
