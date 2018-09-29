using HTTP

using HTTP.LazyHTTP

using Test

import .LazyHTTP.RequestHeader
import .LazyHTTP.ResponseHeader

ifilter(a...) = Base.Iterators.filter(a...)


@testset "LazyHTTP" begin

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


end # testset "LazyHTTP"
