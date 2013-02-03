require("HTTP/Ocean")

app = Ocean.app()

using Ocean.Util

Ocean.get(app, "/", function(req, res, _)
  return "testing"
end)

Ocean.get(app, r"/(.+)", function(req, res, _)
  println(_)
  
  return _.params[1]
end)

BasicServer.bind(8000, Ocean.binding(app), true)
