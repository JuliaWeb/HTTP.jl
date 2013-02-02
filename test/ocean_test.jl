require("HTTP/Ocean")

app = Ocean.app()

println(app)

Ocean.any(app, "/", function(req, res, _)
  return "testing"
end)

BasicServer.bind(8000, Ocean.binding(app), true)
