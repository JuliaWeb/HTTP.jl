require("HTTP/Ocean")

app = Ocean.app()

using Ocean.Util

println(app)
exit()

Ocean.get(app, "/", function(req, res, _)
  res.headers["Content-Type"] = "text/html"
  # f = open(app.source_dir*"/view.html", "r")
  # r = readall(f)
  # close(f)
  
  println(req.cookies)
  
  return _.file("view.html")
end)

Ocean.post(app, "/", function(req, res, _)
  postdata = gs(req.data, "test")
  
  cookie = HTTP.new_cookie("test", postdata, {:expires => Calendar.now() + Calendar.years(10)})
  HTTP.set_cookie(res, cookie)
  
  println(res)
  
  return redirect(res, "/")
end)

Ocean.get(app, r"/(.+)", function(req, res, _)
  #println(_)
  
  # h = {"test" => "test"}
  # println(h["test"])
  # 
  # return _.params[1]
  return false
end)

BasicServer.bind(8000, Ocean.binding(app), true)
