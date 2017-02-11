require("src/HTTP")
require("src/BasicServer")
require("src/Middleware")

function test_app(req, res)
  if isequal(req.path, "/")
    println("old:")
    println(req.env[:session])
    #req.env[:session]["time"] = string(time())
    println("new:")
    println(req.env[:session])
    return "Body"
  elseif isequal(req.path, "/error")
    return [500, "Special error\n"]
  else
    return false
  end
end

app = Middleware.cookie_session(test_app, {
  :key => "test_session",
  :secret => "sekrit"
})

BasicServer.bind(8000, app, true)

