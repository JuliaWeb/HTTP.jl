using HTTP

using HTTP.LazyHTTP

using Test

import .LazyHTTP.RequestHeader
import .LazyHTTP.ResponseHeader

ifilter(a...) = Base.Iterators.filter(a...)


@testset "LazyHTTP" begin

h = RequestHeader("HEAD / HTTP/1.1\r\ncontent-Length: 0\r\n\r\n")

@test h["content-length"] == "0"

@test parse(Int, h["content-length"]) == 0

h = ResponseHeader("""
    HTTP/1.1 302 FOUND\r
    Connection: keep-alive\r
    Server: gunicorn/19.9.0\r
    Date: Mon, 01 Oct 2018 04:51:05 GMT\r
    Content-Type: text/html; charset=utf-8\r
    Content-Length: 0\r
    Location: http://127.0.0.1:8090\r
    Access-Control-Allow-Origin: *\r
    Access-Control-Allow-Credentials: true\r
    Via: 1.1 vegur\r
    \r
    """)

@test HTTP.URIs.URI(h["Location"]).port == "8090"

h = RequestHeader("""
    PUT /http.jl.test/filez HTTP/1.1\r
    Host: s3.ap-southeast-2.amazonaws.com\r
    Content-Length: 3\r
    x-amz-content-sha256: 12345\r
    x-amz-date: 20181001T011722Z\r
    Content-MD5: 12345==\r
    \r
    """)

@test lastindex(h["content-length"]) ==
     firstindex(h["content-length"])

@test strip(h["host"]) == "s3.ap-southeast-2.amazonaws.com"
@test strip(h["content-length"]) == "3"

@test parse(Int, h["content-length"]) == 3

@test lowercase(h["x-amz-date"]) == lowercase("20181001T011722Z")

h = RequestHeader("GET", "/http.jl.test/filez ")
h["Host"] = "s3.ap-southeast-2.amazonaws.com\r"
h["Content-Length"] = "3"
h["x-amz-content-sha256"] = "12345"

@test strip(h["host"]) == "s3.ap-southeast-2.amazonaws.com"
@test strip(h["content-length"]) == "3"
@test String([Iterators.reverse(h["x-amz-content-sha256"])...]) ==
      reverse("12345")

h = ResponseHeader(407)

h["Foo"] = "Bar"
h["Fii"] = "Fum"
h["XXX"] = "YYY"

@test h.status == 407

@test h["Foo"] == "Bar"
@test h["Fii"] == "Fum"
@test h["XXX"] == "YYY"

delete!(h, "Fii")

@test h["Foo"] == "Bar"
@test_throws KeyError h["Fii"] == "Fum"
@test h["XXX"] == "YYY"

h["One"] = "111"
h["Two"] = "222"
h["One"] = "Won"

@test h["Foo"] == "Bar"
@test h["XXX"] == "YYY"
@test h["Two"] == "222"
@test h["One"] == "Won"

io = IOBuffer()
write(io, h)
@test String(take!(io)) == """
    HTTP/1.1 407 Proxy Authentication Required\r
    Foo: Bar\r
    XXX: YYY\r
    Two: 222\r
    One: Won\r
    \r
    """

f_eq_s = LazyHTTP.field_isequal_string
f_eq_f = LazyHTTP.field_isequal_field

@test f_eq_s("A:", 1, "B", 1) == 0

for l in ["Foo-12", "FOO-12", "foo-12"],
    r =  ["Foo-12", "FOO-12", "foo-12"]

    for (c, i) in [(":", 7), ("\n", 0), ("", 0)]
        @test f_eq_s("$l$c", 1, "$r", 1) == i
        @test f_eq_s("$l$c", 1, SubString("$r"), 1) == i
        @test f_eq_s("$l$c", 1, SubString(" $r ", 2, 7), 1) == i
        @test f_eq_s("$l$c", 1, " $r", 2) == i

        @test f_eq_f("$l$c", 1, "$r$c", 1) == i
        @test f_eq_f("$l$c xxx", 1, "$r$c xxx", 1) == i
        @test f_eq_f("$l$c xxx", 1, "$r$c yyy", 1) == i
    end

    @test f_eq_s("$l:", 1, "$r:", 1) == 0
    @test f_eq_s("$l:", 1, " $r:", 2) == 0
    @test f_eq_s("$l:", 1, " $r ", 2) == 0
    @test f_eq_s("$l:", 1, SubString("$r", 1, 5), 1) == 0

    @test f_eq_s("$l\n:", 1, "$r\n", 1) == 0

    @test f_eq_s("$l:a", 1, "$r:a", 1) == 0

    @test f_eq_f("$l\n", 1, "$r\n", 1) == 0
    @test f_eq_f("$l", 1, "$r", 1) == 0
    @test f_eq_f("$l:", 1, "$r", 1) == 0
    @test f_eq_f("$l", 1, "$r:", 1) == 0
    @test f_eq_f("$l: xxx", 1, "$r: yyy", 2) == 0
    @test f_eq_f("$l: xxx", 2, "$r: yyy", 1) == 0
end

s = "GET / HTP/1.1\r\n\r\n"
h = RequestHeader(s)

io = IOBuffer()
write(io, h)
@test String(take!(io)) == s

@test eltype(LazyHTTP.indicies(h)) == Int
@test eltype(keys(h)) == LazyHTTP.FieldName{String}
@test eltype(values(h)) == LazyHTTP.FieldValue{String}
@test eltype(h) == Pair{LazyHTTP.FieldName{String},
                        LazyHTTP.FieldValue{String}}

@test Base.IteratorSize(LazyHTTP.indicies(h)) == Base.SizeUnknown()
@test Base.IteratorSize(h) == Base.SizeUnknown()

@test h.method == "GET"
@test h.target == "/"
@test_throws LazyHTTP.ParseError h.version

s = "SOMEMETHOD HTTP/1.1\r\nContent-Length: 0\r\n\r\n"

h = RequestHeader(s)

@test h.method == "SOMEMETHOD"
@test h.target == "HTTP/1.1"
@test_throws LazyHTTP.ParseError h.version

s = "HTTP/1.1 200\r\n" *
    "A: \r\n" *
    " \r\n" *
    "B: B\r\n" *
    "C:\r\n" *
    " C\r\n" *
    "D: D \r\n" *
    " D   \r\n" *
    " D   \r\n" *
    "\r\n"

h = ResponseHeader(s)

@test eltype(LazyHTTP.indicies(h)) == Int
@test eltype(keys(h)) == LazyHTTP.FieldName{String}
@test eltype(values(h)) == LazyHTTP.FieldValue{String}
@test eltype(h) == Pair{LazyHTTP.FieldName{String},
                        LazyHTTP.FieldValue{String}}

@test h["A"] == " "
@test h["B"] == "B"
@test h["C"] == " C"
@test h["D"] == "D  D    D"

s = "HTTP/1.1 200 OK\r\n" *
    "Foo: \t Bar Bar\t  \r\n" *
    "X: Y  \r\n" *
    "X:  Z \r\n" *
    "XX: Y  \r\n" *
    "XX:  Z \r\n" *
    "Field: Value\n folded \r\n more fold\n" *
    "Blah: x\x84x" *
    "\r\n" *
    "\r\n"

h = ResponseHeader(s)

@test (@allocated h = ResponseHeader(s)) <= 32

@test h.status == 200
@test (@allocated h.status) == 0
@test h.version == v"1.1"
@test (@allocated h.version) <= 48

f = h["Foo"]
ff = "Bar Bar"
@test h["Foo"] == ff
@test count(x->true, keys(f)) == length(keys(ff))
for (c, k, kk)  in zip(f, keys(f), keys(ff))
    @test c == f[k]
    @test f[k] == ff[kk]
end

@test h["X"] == "Y"
@test collect(ifilter(p -> p.first == "X", h)) == ["X" => "Y", "X" => "Z"]
@test h["XX"] == "Y"
@test collect(ifilter(p -> p.first == "XX", h)) == ["XX" => "Y", "XX" => "Z"]

@test collect(keys(h)) == ["Foo", "X", "X", "XX", "XX", "Field", "Blah"]
if LazyHTTP.ENABLE_OBS_FOLD
@test collect(h) == ["Foo" => "Bar Bar",
                     "X" => "Y",
                     "X" => "Z",
                     "XX" => "Y",
                     "XX" => "Z",
                     "Field" => "Value folded  more fold",
                     "Blah" => "x\x84x"]
else
@test h["Field"] != "Foo"
@test h["Field"] != "Valu"
@test_throws LazyHTTP.ParseError h["Field"] == "Value"
@test_throws LazyHTTP.ParseError h["Field"] == "Value folded  more fold"
@test [n => h[n] for n in ifilter(x->x != "Field", keys(h))] ==
    ["Foo" => "Bar Bar",
     "X" => "Y",
     "X" => "Z",
     "XX" => "Y",
     "XX" => "Z",
     "Blah" => "x\x84x"]
end

@test (@allocated keys(h)) <= 16
@test iterate(keys(h)) == ("Foo", 18)
@test (@allocated iterate(keys(h))) <= 80

@test SubString(h["Foo"]).string == s
@test SubString(h["Blah"]).string == s
@test SubString(h["X"]).string == s
if LazyHTTP.ENABLE_OBS_FOLD
@test SubString(h["Field"]).string != s
end

@test (@allocated SubString(h["Blah"])) <= 64

@test all(n->SubString(n).string == s, keys(h))

@test haskey(h, "Foo")
@test haskey(h, "FOO")
@test haskey(h, "foO")
@test (@allocated haskey(h, "Foo")) == 0
@test (@allocated haskey(h, "XXx")) == 0

if LazyHTTP.ENABLE_OBS_FOLD
@test [h[n] for n in keys(h)] == ["Bar Bar",
                                  "Y",
                                  "Z",
                                  "Y",
                                  "Z",
                                  "Value folded  more fold",
                                  "x\x84x"]

@test [h[n] for n in keys(h)] == [x for x in values(h)]
@test [h[n] for n in keys(h)] == [String(x) for x in values(h)]
@test [h[n] for n in keys(h)] == [SubString(x) for x in values(h)]
else
@test [h[n] for n in ifilter(x->x != "Field", keys(h))] == ["Bar Bar",
                                  "Y",
                                  "Z",
                                  "Y",
                                  "Z",
                                  "x\x84x"]
end



s = "GET /foobar HTTP/1.1\r\n" *
    "Foo: \t Bar Bar\t  \r\n" *
    "X: Y  \r\n" *
    "Field: Value\n folded \r\n more fold\n" *
    "Blah: x\x84x" *
    "\r\n" *
    "\r\n"

@test !isvalid(RequestHeader(s))
@test isvalid(RequestHeader(s); obs=true)

@test LazyHTTP.method(RequestHeader(s)) == "GET"
@test LazyHTTP.target(RequestHeader(s)) == "/foobar"
@test LazyHTTP.version(RequestHeader(s)) == v"1.1"

@test RequestHeader(s).method == "GET"
@test RequestHeader(s).target == "/foobar"
@test RequestHeader(s).version == v"1.1"
@test LazyHTTP.version_is_1_1(RequestHeader(s))


h = RequestHeader(s)
@test h.method == "GET"
@test (@allocated h.method) <= 32


function lazy_parse(s, a, b)
    h = ResponseHeader(s)
    #collect(SubString(n) => SubString(v) for (n,v) in h)
    return h.status == 200, SubString(h[a]), SubString(h[b])
end

#=

function old_parse(s, a, b)
    r = HTTP.Response()
    s = HTTP.Parsers.parse_status_line!(s, r)
    HTTP.Messages.parse_header_fields!(s, r)
    return r.status == 200, HTTP.header(r, a), HTTP.header(r, b)
end


function lazy_send(io, status, headers)
    h = ResponseHeader(status)
    for x in headers
        push!(h, x)
    end
    write(io, h)
end

function old_send(io, status, headers)
    r = HTTP.Response(status)
    for x in headers
        HTTP.appendheader(r, x)
    end
    write(io, r)
end


using InteractiveUtils

println("----------------------------------------------")
println("LazyHTTP performance (vs HTTP.Parsers)")
println("----------------------------------------------")
for (n,r) in include("responses.jl")

    h = ResponseHeader(r)
    last_header = String(last(collect((keys(h)))))

    @test lazy_parse(r, "Content-Type", last_header) ==
           old_parse(r, "Content-Type", last_header)

    aa = Base.gc_alloc_count(
            (@timed lazy_parse(r, "Content-Type", last_header))[5])
    ab = Base.gc_alloc_count(
            (@timed old_parse(r, "Content-Type", last_header))[5])

    Base.GC.gc()
    ta = (@timed for i in 1:10000
            lazy_parse(r, "Content-Type", last_header)
          end)[2]
    Base.GC.gc()
    tb = (@timed for i in 1:10000
            old_parse(r, "Content-Type", last_header)
          end)[2]

    println(rpad("$n header:", 18) *
            "$(lpad(round(Int, 100*aa/ab), 2))% allocs, " *
            "$(lpad(round(Int, 100*ta/tb), 2))% time")
end
println("----------------------------------------------")



println("----------------------------------------------")
println("LazyHTTP send performance (vs HTTP.Response)")
println("----------------------------------------------")
for (n,r) in include("responses.jl")

    h = ResponseHeader(r)
    status = h.status
    test_headers = [String(n) => String(v) for (n,v) in h]

    a = IOBuffer()
    lazy_send(a, status, test_headers)
    b = IOBuffer()
    old_send(b, status, test_headers)

    a = String(take!(a))
    b = String(take!(b))
    @test a == b

    a = IOBuffer()
    b = IOBuffer()
    aa = Base.gc_alloc_count((@timed lazy_send(a, status, test_headers))[5])
    ab = Base.gc_alloc_count((@timed old_send(b, status, test_headers))[5])

    a = IOBuffer(sizehint = 1000000)
    Base.GC.gc()
    ta = (@timed for i in 1:10000 lazy_send(a, status, test_headers) end)[2]
    b = IOBuffer(sizehint = 1000000)
    Base.GC.gc()
    tb = (@timed for i in 1:10000 old_send(a, status, test_headers) end)[2]

    println(rpad("$n header:", 18) *
            "$(lpad(round(Int, 100*aa/ab), 3))% allocs, " *
            "$(lpad(round(Int, 100*ta/tb), 3))% time")
end
println("----------------------------------------------")

=#


end # testset "LazyHTTP"
