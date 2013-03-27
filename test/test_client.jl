require("src/Client")

conn = HTTPClient.open("google.com", 80)
# println(conn)

HTTPClient.get(conn, "/")

HTTPClient.close(conn)
