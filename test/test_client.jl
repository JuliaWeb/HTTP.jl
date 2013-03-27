require("src/Client")

conn = HTTPClient.open("google.com", 80)
# println(conn)

res = HTTPClient.get(conn, "/")
println(res)

HTTPClient.close(conn)
