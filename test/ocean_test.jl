require("HTTP/Ocean")

app = Ocean.app()

using Ocean.Util

Ocean.get(app, "/", function(req, res, _)
  res.headers["Content-Type"] = "text/html"
  f = open(app.source_dir*"/view.html", "r")
  r = readall(f)
  close(f)
  return r
end)

Ocean.post(app, "/", function(req, res, _)
  return req.data["test"][1]
end)

Ocean.get(app, r"/(.+)", function(req, res, _)
  println(_)
  
  # return _.params[1]
  return false
end)

BasicServer.bind(8000, Ocean.binding(app), true)
