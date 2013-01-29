include("HTTP.jl")
include("BasicServer.jl")

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
    path::String
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
  
  function get(app::App, path::String, handler::Function)
    _route = Route("GET", path, Dict{Any,Any}(), handler)
    
    route(app, _route)
  end
  
  function route(app::App, _route::Route)
    push!(app.routes, _route)
  end
  
  function route(app::App, method::String, path::String, opts::Dict{Any,Any}, handler::Function)
    _route = Route(method, path, opts, handler)
    route(app, _route)
  end
  
end
