require("HTTP/Ocean")

app = Ocean.app()

using Ocean.Util

Ocean.get(app, "/", function(req, res, _)
  res.headers["Content-Type"] = "text/html"
  # f = open(app.source_dir*"/view.html", "r")
  # r = readall(f)
  # close(f)
  return _.file("view.html")
end)

Ocean.post(app, "/", function(req, res, _)
  return gs(req.data, "test")
end)

Ocean.get(app, r"/(.+)", function(req, res, _)
  #println(_)
  
  h = {"test" => "test"}
  println(h["test"])
  
  return _.params[1]
  return false
end)

BasicServer.bind(8000, Ocean.binding(app), true)
