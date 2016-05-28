using HttpCommon
using Base.Test
using Compat
import Compat: UTF8String
# headers
@test isa(HttpCommon.headers(), Headers)

# Request
@test sprint(show, Request()) == "Request(:/, 0 headers, 0 bytes in body)"
@test sprint(show, Request("GET", "/get", HttpCommon.headers(), "")) ==
        "Request(:/, 4 headers, 0 bytes in body)"

# Cookie
@test sprint(show, Cookie("test","it")) ==
        "Cookie(test, it, 0 attributes)"

# Response
h = HttpCommon.headers()
@test sprint(show, Response(200, h, "HttpCommon")) ==
        "Response(200 OK, 4 headers, 10 bytes in body)"
@test sprint(show, Response(200, h, UInt8[1,2,3])) ==
        "Response(200 OK, 4 headers, 3 bytes in body)"
@test sprint(show, Response(200, h)) ==
        "Response(200 OK, 4 headers, 0 bytes in body)"
@test sprint(show, Response(200, "HttpCommon")) ==
        "Response(200 OK, 4 headers, 10 bytes in body)"
@test sprint(show, Response(200, UInt8[1,2,3])) ==
        "Response(200 OK, 4 headers, 3 bytes in body)"
@test sprint(show, Response("HttpCommon", h)) ==
        "Response(200 OK, 4 headers, 10 bytes in body)"
@test sprint(show, Response(UInt8[1,2,3], h)) ==
        "Response(200 OK, 4 headers, 3 bytes in body)"
@test sprint(show, Response("HttpCommon")) ==
        "Response(200 OK, 4 headers, 10 bytes in body)"
@test sprint(show, Response(UInt8[1,2,3])) ==
        "Response(200 OK, 4 headers, 3 bytes in body)"
@test sprint(show, Response(200)) ==
        "Response(200 OK, 4 headers, 0 bytes in body)"
@test sprint(show, Response()) ==
        "Response(200 OK, 4 headers, 0 bytes in body)"

# Escape HTML
@test escapeHTML("<script type='text/javascript'>alert('sucker');</script> foo bar") ==
        "&lt;script type=&#39;text/javascript&#39;&gt;alert(&#39;sucker&#39;);&lt;/script&gt; foo bar"

# Parse URL query strings
@test parsequerystring("foo=%3Ca%20href%3D%27foo%27%3Ebar%3C%2Fa%3Erun%26%2B%2B&bar=123") ==
        Dict("foo" => "<a href='foo'>bar</a>run&++", "bar" => "123")

begin
  substrings = split(UTF8String("a%20=1&b=%202,b,c"), ",")
  @test parsequerystring(substrings[1]) == Dict("a " => "1", "b" => " 2")
end
@test parsequerystring("") == Dict()
@test_throws ArgumentError parsequerystring("looknopairs")
@test_throws ArgumentError parsequerystring("good=pair&badpair")
