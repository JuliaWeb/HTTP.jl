@testset "Cookies" begin
    c = HTTP.Cookies.Cookie()
    @test c.name == ""
    @test HTTP.Cookies.domainmatch(c, "")

    c.path = "/any"
    @test HTTP.Cookies.pathmatch(c, "/any/path")
    @test !HTTP.Cookies.pathmatch(c, "/nottherightpath")

    writesetcookietests = [
	(HTTP.Cookie("cookie-1", "v\$1"), "cookie-1=v\$1"),
	(HTTP.Cookie("cookie-2", "two", maxage=3600), "cookie-2=two; Max-Age=3600"),
	(HTTP.Cookie("cookie-3", "three", domain=".example.com"), "cookie-3=three; Domain=example.com"),
	(HTTP.Cookie("cookie-4", "four", path="/restricted/"), "cookie-4=four; Path=/restricted/"),
	(HTTP.Cookie("cookie-5", "five", domain="wrong;bad.abc"), "cookie-5=five"),
	(HTTP.Cookie("cookie-6", "six", domain="bad-.abc"), "cookie-6=six"),
	(HTTP.Cookie("cookie-7", "seven", domain="127.0.0.1"), "cookie-7=seven; Domain=127.0.0.1"),
	(HTTP.Cookie("cookie-8", "eight", domain="::1"), "cookie-8=eight"),
	(HTTP.Cookie("cookie-9", "expiring", expires=Dates.unix2datetime(1257894000)), "cookie-9=expiring; Expires=Tue, 10 Nov 2009 23:00:00 GMT"),
	# According to IETF 6265 Section 5.1.1.5, the year cannot be less than 1601
	(HTTP.Cookie("cookie-10", "expiring-1601", expires=Dates.DateTime(1601, 1, 1, 1, 1, 1, 1)), "cookie-10=expiring-1601; Expires=Mon, 01 Jan 1601 01:01:01 GMT"),
	(HTTP.Cookie("cookie-11", "invalid-expiry", expires=Dates.DateTime(1600, 1, 1, 1, 1, 1, 1)), "cookie-11=invalid-expiry"),
	# The "special" cookies have values containing commas or spaces which
	# are disallowed by RFC 6265 but are common in the wild.
	(HTTP.Cookie("special-1", "a z"), "special-1=a z"),
	(HTTP.Cookie("special-2", " z"), "special-2=\" z\""),
	(HTTP.Cookie("special-3", "a "), "special-3=\"a \""),
	(HTTP.Cookie("special-4", " "), "special-4=\" \""),
	(HTTP.Cookie("special-5", "a,z"), "special-5=a,z"),
	(HTTP.Cookie("special-6", ",z"), "special-6=\",z\""),
	(HTTP.Cookie("special-7", "a,"), "special-7=\"a,\""),
	(HTTP.Cookie("special-8", ","), "special-8=\",\""),
	(HTTP.Cookie("empty-value", ""), "empty-value="),
	(HTTP.Cookie("", ""), ""),
	(HTTP.Cookie("\t", ""), ""),
]

@testset "String(::Cookie)" begin
    for (cookie, expected) in writesetcookietests
        @test String(cookie, false) == expected
    end

    cookies = [HTTP.Cookie("cookie-1", "v\$1"),
    		   HTTP.Cookie("cookie-2", "v\$2"),
    		   HTTP.Cookie("cookie-3", "v\$3"),
    		  ]
    @test string("", cookies) == "cookie-1=v\$1; cookie-2=v\$2; cookie-3=v\$3"
end

@testset "readsetcookies" begin
    cookietests = [
        (Dict(["Set-Cookie"=> "Cookie-1=v\$1"]), [HTTP.Cookie("Cookie-1", "v\$1")]),
        (Dict(["Set-Cookie"=> "NID=99=YsDT5i3E-CXax-; expires=Wed, 23-Nov-2011 01:05:03 GMT; path=/; domain=.google.ch; HttpOnly"]),
            [HTTP.Cookie("NID", "99=YsDT5i3E-CXax-"; path="/", domain="google.ch", httponly=true, expires=Dates.DateTime(2011, 11, 23, 1, 5, 3, 0))]),
        (Dict(["Set-Cookie"=> ".ASPXAUTH=7E3AA; expires=Wed, 07-Mar-2012 14:25:06 GMT; path=/; HttpOnly"]),
            [HTTP.Cookie(".ASPXAUTH", "7E3AA"; path="/", expires=Dates.DateTime(2012, 3, 7, 14, 25, 6, 0), httponly=true)]),
        (Dict(["Set-Cookie"=> "ASP.NET_SessionId=foo; path=/; HttpOnly"]),
            [HTTP.Cookie("ASP.NET_SessionId", "foo"; path="/", httponly=true)]),
        (Dict(["Set-Cookie"=> "special-1=a z"]),  [HTTP.Cookie("special-1", "a z")]),
        (Dict(["Set-Cookie"=> "special-2=\" z\""]), [HTTP.Cookie("special-2", " z")]),
        (Dict(["Set-Cookie"=> "special-3=\"a \""]), [HTTP.Cookie("special-3", "a ")]),
        (Dict(["Set-Cookie"=> "special-4=\" \""]),  [HTTP.Cookie("special-4", " ")]),
        (Dict(["Set-Cookie"=> "special-5=a,z"]),  [HTTP.Cookie("special-5", "a,z")]),
        (Dict(["Set-Cookie"=> "special-6=\",z\""]), [HTTP.Cookie("special-6", ",z")]),
        (Dict(["Set-Cookie"=> "special-7=a,"]),   [HTTP.Cookie("special-7", "a,")]),
        (Dict(["Set-Cookie"=> "special-8=\",\""]),  [HTTP.Cookie("special-8", ",")]),
    ]

    for (h, c) in cookietests
        @test HTTP.Cookies.readsetcookies("", [Dict(h)["Set-Cookie"]]) == c
    end
end

@testset "SetCookieDoubleQuotes" begin
    cookiestrings = [
        "quoted0=none; max-age=30",
        "quoted1=\"cookieValue\"; max-age=31",
        "quoted2=cookieAV; max-age=\"32\"",
        "quoted3=\"both\"; max-age=\"33\"",
    ]
    want = [
        HTTP.Cookie("quoted0", "none", maxage=30),
        HTTP.Cookie("quoted1", "cookieValue", maxage=31),
        HTTP.Cookie("quoted2", "cookieAV"),
        HTTP.Cookie("quoted3", "both"),
    ]
    @test all(HTTP.Cookies.readsetcookies("", cookiestrings) .== want)
end

@testset "Cookie sanitize value" begin
    values = Dict(
        "foo" => "foo",
        "foo;bar" => "foobar",
        "foo\\bar" => "foobar",
        "foo\"bar" => "foobar",
        String(UInt8[0x00, 0x7e, 0x7f, 0x80]) => String(UInt8[0x7e]),
        "\"withquotes\"" => "withquotes",
        "a z" => "a z",
        " z" => "\" z\"",
        "a " => "\"a \"",
    )
    for (k, v) in values
        @test HTTP.Cookies.sanitizeCookieValue(k) == v
    end
end

@testset "Cookie sanitize path" begin
    paths = Dict(
        "/path" => "/path",
        "/path with space/" => "/path with space/",
        "/just;no;semicolon\0orstuff/" => "/justnosemicolonorstuff/",
    )
    for (k, v) in paths
        @test HTTP.Cookies.sanitizeCookiePath(k) == v
    end
end

@testset "HTTP.readcookies" begin
    testcookies = [
        (Dict("Cookie" => "Cookie-1=v\$1; c2=v2"), "", [HTTP.Cookie("Cookie-1", "v\$1"), HTTP.Cookie("c2", "v2")]),
        (Dict("Cookie" => "Cookie-1=v\$1; c2=v2"), "c2", [HTTP.Cookie("c2", "v2")]),
        (Dict("Cookie" => "Cookie-1=v\$1; c2=v2"), "", [HTTP.Cookie("Cookie-1", "v\$1"), HTTP.Cookie("c2", "v2")]),
        (Dict("Cookie" => "Cookie-1=v\$1; c2=v2"), "c2", [HTTP.Cookie("c2", "v2")]),
        (Dict("Cookie" => "Cookie-1=\"v\$1\"; c2=\"v2\""), "", [HTTP.Cookie("Cookie-1", "v\$1"), HTTP.Cookie("c2", "v2")]),
    ]
    for (h, filter, cookies) in testcookies
        @test HTTP.Cookies.readcookies(h, filter) == cookies
    end
end
end; # @testset "Cookies"
