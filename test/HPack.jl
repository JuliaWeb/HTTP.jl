using Test
using HTTP
using LazyJSON
using Random

include("../src/HPack.jl")

function hexdump(s)
    mktemp() do path, io
        write(io, s)
        close(io)
        return read(`xxd -r -p $path`)
    end
end

#@testset "HPack" begin

@testset "HPack.integer" begin


# Min value
bytes = [0b00000000]
i, v = HPack.hp_integer(bytes, 1, 0b11111111)
@test i == 2
@test v == 0


# Max value
bytes = [0b11111111,
         0b11111111,
         0b11111111,
         0b01111111]
i, v = HPack.hp_integer(bytes, 1, 0b11111111)
@test i == 5
@test v == 2097406


#=
C.1.1 Example 1: Encoding 10 Using a 5-Bit Prefix
  0   1   2   3   4   5   6   7
+---+---+---+---+---+---+---+---+
| X | X | X | 0 | 1 | 0 | 1 | 0 |   10 stored on 5 bits
+---+---+---+---+---+---+---+---+
=#
bytes = [0b11101010]
i, v = HPack.hp_integer(bytes, 1, 0b00011111)
@test i == 2
@test v == 10


#=
C.1.2 Example 2: Encoding 1337 Using a 5-Bit Prefix
  0   1   2   3   4   5   6   7
+---+---+---+---+---+---+---+---+
| X | X | X | 1 | 1 | 1 | 1 | 1 |  Prefix = 31, I = 1306
| 1 | 0 | 0 | 1 | 1 | 0 | 1 | 0 |  1306>=128, encode(154), I=1306/128
| 0 | 0 | 0 | 0 | 1 | 0 | 1 | 0 |  10<128, encode(10), done
+---+---+---+---+---+---+---+---+
=#
bytes = [0b00011111,
         0b10011010,
         0b00001010]

i, v = HPack.hp_integer(bytes, 1, 0b00011111)
@test i == 4
@test v == 1337


#=
C.1.3 Example 3: Encoding 42 Starting at an Octet Boundary
  0   1   2   3   4   5   6   7
+---+---+---+---+---+---+---+---+
| 0 | 0 | 1 | 0 | 1 | 0 | 1 | 0 |   42 stored on 8 bits
+---+---+---+---+---+---+---+---+
=#
bytes = [0b00101010]
i, v = HPack.hp_integer(bytes, 1, 0b11111111)
@test i == 2
@test v == 42


end # @testset HPack.integer


@testset "HPack.ascii" begin

HPackString = HPack.HPackString

s = HPack.HPackString([0x00], 1)
@test convert(String, s) == ""

bytes = hexdump("""
    400a 6375 7374 6f6d 2d6b 6579 0d63 7573 | @.custom-key.cus
    746f 6d2d 6865 6164 6572                | tom-header
    """)


key = HPackString(bytes, 2)
value = HPackString(bytes, 13)

@test key == key
@test value == value
@test key != value

@test String(collect(key)) == "custom-key"
@test convert(String, key) == "custom-key"

@test String(collect(value)) == "custom-header"
@test convert(String, value) == "custom-header"
@test value == HPackString("custom-header")
@test HPackString("custom-header") == value

@test "$key: $value" == "custom-key: custom-header"

for T in (String, SubString, HPackString)
    @test key == T("custom-key")
    @test T("custom-key") == key
    for s in ("cUstom-key", "custom-kex", "custom-ke", "custom-keyx")
        @test key != T(s)
        @test T(s) != key
    end
end

end # @testset HPack.ascii


@testset "HPack.huffman" begin

HPackString = HPack.HPackString

bytes = hexdump("""
    8287 85bf 4088 25a8 49e9 5ba9 7d7f 8925 | ....@.%.I.[.}..%
    a849 e95b b8e8 b4bf                     | .I.[....
    """)
key = HPackString(bytes, 6)
value = HPackString(bytes, 15)

@test key == key
@test value == value
@test key != value

@test convert(String, key) == "custom-key"
@test convert(String, value) == "custom-value"

@test "$key: $value" == "custom-key: custom-value"

for T in (String, SubString, HPackString)
    @test key == T("custom-key")
    @test T("custom-key") == key
    for s in ("cUstom-key", "custom-kex", "custom-ke", "custom-keyx")
        @test key != T(s)
        @test T(s) != key
    end
end

end # @testset HPack.huffman

@testset "HPack.fields" begin

#=
C.6.1.  First Response

   Header list to encode:

   :status: 302
   cache-control: private
   date: Mon, 21 Oct 2013 20:13:21 GMT
   location: https://www.example.com

   Hex dump of encoded data:
=#
bytes = hexdump("""
    4882 6402 5885 aec3 771a 4b61 96d0 7abe | H.d.X...w.Ka..z.
    9410 54d4 44a8 2005 9504 0b81 66e0 82a6 | ..T.D. .....f...
    2d1b ff6e 919d 29ad 1718 63c7 8f0b 97c8 | -..n..)...c.....
    e9ae 82ae 43d3                          | ....C.
    """)

i::UInt = 1

j, idx = HPack.hp_integer(bytes, i, 0b00111111)
@test idx == 8
@test HPack.HPackString(bytes, j) == "302"

i = HPack.hp_field_nexti(bytes, i)
j, idx = HPack.hp_integer(bytes, i, 0b00111111)
@test idx == 24
@test HPack.HPackString(bytes, j) == "private"

i = HPack.hp_field_nexti(bytes, i)
j, idx = HPack.hp_integer(bytes, i, 0b00111111)
@test idx == 33
@test HPack.HPackString(bytes, j) == "Mon, 21 Oct 2013 20:13:21 GMT"

i = HPack.hp_field_nexti(bytes, i)
j, idx = HPack.hp_integer(bytes, i, 0b00111111)
@test idx == 46
@test HPack.HPackString(bytes, j) == "https://www.example.com"

i = HPack.hp_field_nexti(bytes, i)

@test i == length(bytes) + 1

b = HPack.HPackBlock(HPack.HPackSession(), bytes, 1)

#=
b = Iterators.Stateful(b)

j, idx = HPack.hp_integer(bytes, popfirst!(b), 0b00111111)
@test idx == 8
@test HPack.HPackString(bytes, j) == "302"

j, idx = HPack.hp_integer(bytes, popfirst!(b), 0b00111111)
@test idx == 24
@test HPack.HPackString(bytes, j) == "private"

j, idx = HPack.hp_integer(bytes, popfirst!(b), 0b00111111)
@test idx == 33
@test HPack.HPackString(bytes, j) == "Mon, 21 Oct 2013 20:13:21 GMT"

j, idx = HPack.hp_integer(bytes, popfirst!(b), 0b00111111)
@test idx == 46
@test HPack.HPackString(bytes, j) == "https://www.example.com"

@test isempty(b)
=#

@test collect(b) == [
    ":status" => "302",
    "cache-control" => "private",
    "date" => "Mon, 21 Oct 2013 20:13:21 GMT",
    "location" => "https://www.example.com"
]

ascii_requests = [
    hexdump("""
    8286 8441 0f77 7777 2e65 7861 6d70 6c65
    2e63 6f6d
    """),

    hexdump("""
    8286 84be 5808 6e6f 2d63 6163 6865
    """),

    hexdump("""
    8287 85bf 400a 6375 7374 6f6d 2d6b 6579
    0c63 7573 746f 6d2d 7661 6c75 65
    """)
]

huffman_requests = [
    hexdump("""
    8286 8441 8cf1 e3c2 e5f2 3a6b a0ab 90f4
    ff
    """),

    hexdump("""
    8286 84be 5886 a8eb 1064 9cbf
    """),

    hexdump("""
    8287 85bf 4088 25a8 49e9 5ba9 7d7f 8925
    a849 e95b b8e8 b4bf
    """)
]

for r in (ascii_requests, huffman_requests)

    s = HPack.HPackSession()
    b1 = HPack.HPackBlock(s, r[1], 1)

    for rep in 1:3
        @test collect(b1) == [
           ":method" => "GET",
           ":scheme" => "http",
           ":path" => "/",
           ":authority" => "www.example.com"
        ]
        #@test s.table_size == 57

        @test b1.authority == "www.example.com"
        @test b1.scheme == "http"
        @test b1.method == "GET"
        @test b1.path == "/"
    end

    b2 = HPack.HPackBlock(s, r[2], 1)

    for rep in 1:3
        @test b2.scheme == "http"
        @test b2.authority == "www.example.com"
        @test b2.method == "GET"
        @test b2.path == "/"

        @test collect(b2) == [
           ":method" => "GET",
           ":scheme" => "http",
           ":path" => "/",
           ":authority" => "www.example.com",
           "cache-control" => "no-cache"
        ]
        #@test s.table_size == 110
    end

    b3 = HPack.HPackBlock(s, r[3], 1)

    for rep in 1:3
        @test b3.scheme == "https"
        @test b3.path == "/index.html"
        @test b3.authority == "www.example.com"

        @test collect(b3) == [
           ":method" => "GET",
           ":scheme" => "https",
           ":path" => "/index.html",
           ":authority" => "www.example.com",
           "custom-key" => "custom-value"
        ]

        @test b3.method == "GET"

        #@test s.table_size == 164
    end

    @test split(string(s), "\n")[2:end] == [
        "    [62] custom-key: custom-value",
        "    [63] cache-control: no-cache",
        "    [64] :authority: www.example.com", "", ""]
end

ascii_responses = [
    hexdump("""
    4803 3330 3258 0770 7269 7661 7465 611d
    4d6f 6e2c 2032 3120 4f63 7420 3230 3133
    2032 303a 3133 3a32 3120 474d 546e 1768
    7474 7073 3a2f 2f77 7777 2e65 7861 6d70
    6c65 2e63 6f6d
    """),

    hexdump("""
    4803 3330 37c1 c0bf
    """),

    hexdump("""
    88c1 611d 4d6f 6e2c 2032 3120 4f63 7420
    3230 3133 2032 303a 3133 3a32 3220 474d
    54c0 5a04 677a 6970 7738 666f 6f3d 4153
    444a 4b48 514b 425a 584f 5157 454f 5049
    5541 5851 5745 4f49 553b 206d 6178 2d61
    6765 3d33 3630 303b 2076 6572 7369 6f6e
    3d31
    """)
]

huffman_responses = [
    hexdump("""
    4882 6402 5885 aec3 771a 4b61 96d0 7abe
    9410 54d4 44a8 2005 9504 0b81 66e0 82a6
    2d1b ff6e 919d 29ad 1718 63c7 8f0b 97c8
    e9ae 82ae 43d3
    """),

    hexdump("""
    4883 640e ffc1 c0bf
    """),

    hexdump("""
    88c1 6196 d07a be94 1054 d444 a820 0595
    040b 8166 e084 a62d 1bff c05a 839b d9ab
    77ad 94e7 821d d7f2 e6c7 b335 dfdf cd5b
    3960 d5af 2708 7f36 72c1 ab27 0fb5 291f
    9587 3160 65c0 03ed 4ee5 b106 3d50 07
    """)
]

for r in (ascii_responses, huffman_responses)

    s = HPack.HPackSession()
    s.max_table_size = 256

    b1 = HPack.HPackBlock(s, r[1], 1)
    collect(b1)
    #@test s.table_size == 222

    b2 = HPack.HPackBlock(s, r[2], 1)
    collect(b2)
    collect(b2)
    #@test s.table_size == 222

    b3 = HPack.HPackBlock(s, r[3], 1)
    @test collect(b3) == [
        ":status"=>"200",
        "cache-control"=>"private",
        "date"=>"Mon, 21 Oct 2013 20:13:22 GMT",
        "location"=>"https://www.example.com",
        "content-encoding"=>"gzip",
        "set-cookie"=>"foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"
    ]
    #@test s.table_size == 215
    #@show s
end

end # @testset HPack.fields


# See https://github.com/http2jp/hpack-test-case
url = "https://raw.githubusercontent.com/http2jp/hpack-test-case/master"

cachedir() = joinpath(@__DIR__, "http2jp")
cachehas(file) = isfile(joinpath(cachedir(), file))
cacheget(file) = read(joinpath(cachedir(), file))

function cacheput(file, data)
    p = joinpath(cachedir(), file)
    mkpath(dirname(p))
    write(p, data)
end


for group in [
    "go-hpack",
    "haskell-http2-linear-huffman",
    "haskell-http2-linear",
    "haskell-http2-naive-huffman",
    "haskell-http2-naive",
    "haskell-http2-static-huffman",
    "haskell-http2-static",
    "nghttp2-16384-4096",
    "nghttp2-change-table-size",
    "nghttp2",
    "node-http2-hpack",
    "python-hpack"
]
    @testset "$group" begin
        for name in ("$group/story_$(lpad(n, 2, '0')).json" for n in 0:31)
            if cachehas(name)
                tc = cacheget(name)
            else
                tc = try
                    HTTP.get("$url/$name").body
                catch e
                    if e isa HTTP.StatusError && e.status == 404
                        println("$name 404 not found")
                        tc = "{\"cases\":[]}"
                    else
                        rethrow(w)
                    end
                end
                cacheput(name, tc)
            end
            @testset "$group.$name" begin
                tc = LazyJSON.value(tc)
                #println(tc.description)
                for seq in [(1,1,2), (1,2,1), (2,1,1)]
                    s = HPack.HPackSession()
                    for case in tc.cases
                        if haskey(case, "header_table_size")
                            s.max_table_size = case.header_table_size
                        end
                        block = HPack.HPackBlock(s, hex2bytes(case.wire), 1)
                        t = [()-> for (a, b) in zip(block, case.headers)
                                @test a == first(b)
                            end,
                            ()->for h in shuffle(case.headers)
                                n, v = first(h)
                                if count(isequal(n), keys(block)) == 1
                                    @test block[n] == v
                                else
                                    @test (n => v) in
                                          Iterators.filter(x->x[1] == n, block)
                                end
                            end]
                        for i in seq
                            t[i]()
                        end
                    end
                end
            end
        end
    end
end

#end # @testset HPack
