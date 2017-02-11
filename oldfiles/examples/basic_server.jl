require("HTTP")
require("HTTP/src/BasicServer")

function test_app(req, res)
  if isequal(req.path, "/")
    sleep(rand())
    return "Hello world"
  elseif isequal(req.path, "/error")
    return [500, "Special error\n"]
  else
    return nothing
  end
end

BasicServer.bind(8000, test_app, true)
