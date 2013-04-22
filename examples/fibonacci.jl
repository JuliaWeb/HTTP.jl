using HttpServer

function fibonacci(n)
  if n == 1 return 1 end
  if n == 2 return 1 end
  prev = BigInt(1)
  pprev = BigInt(1)
  for i=3:n
    curr = prev + pprev 
    pprev = prev
    prev = curr
  end
  return prev
end

http = HttpHandler() do req::Request, res::Response
    m = match(r"^/fibo/(\d+)/?$",req.resource)
    if m == nothing return Response(404) end
    number = BigInt(m.captures[1])
    if number < 1 || number > 100_000 return Response(500) end
    return Response(string(fibonacci(number)))
end

http.events["error"]  = (client, err) -> println(err)
http.events["listen"] = (port)        -> println("Listening on $port...")

server = Server(http)
run(server, 8000)
