module TestCookies

using HTTP
using Sockets, Test

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
        (HTTP.Cookie("cookie-9", "expiring", expires=HTTP.Dates.unix2datetime(1257894000)), "cookie-9=expiring; Expires=Tue, 10 Nov 2009 23:00:00 GMT"),

        # According to IETF 6265 Section 5.1.1.5, the year cannot be less than 1601
        (HTTP.Cookie("cookie-10", "expiring-1601", expires=HTTP.Dates.DateTime(1601, 1, 1, 1, 1, 1, 1)), "cookie-10=expiring-1601; Expires=Mon, 01 Jan 1601 01:01:01 GMT"),
        (HTTP.Cookie("cookie-11", "invalid-expiry", expires=HTTP.Dates.DateTime(1600, 1, 1, 1, 1, 1, 1)), "cookie-11=invalid-expiry"),

        # The "special" cookies have values containing commas or spaces which
        # are disallowed by RFC 6265 but are common in the wild.
        (HTTP.Cookie("special-1", "a z"), "special-1=\"a z\""),
        (HTTP.Cookie("special-2", " z"), "special-2=\" z\""),
        (HTTP.Cookie("special-3", "a "), "special-3=\"a \""),
        (HTTP.Cookie("special-4", " "), "special-4=\" \""),
        (HTTP.Cookie("special-5", "a,z"), "special-5=\"a,z\""),
        (HTTP.Cookie("special-6", ",z"), "special-6=\",z\""),
        (HTTP.Cookie("special-7", "a,"), "special-7=\"a,\""),
        (HTTP.Cookie("special-8", ","), "special-8=\",\""),
        (HTTP.Cookie("empty-value", ""), "empty-value="),
        (HTTP.Cookie("", ""), ""),
        (HTTP.Cookie("\t", ""), ""),
    ]

    @testset "stringify(::Cookie)" begin
        for (cookie, expected) in writesetcookietests
            @test HTTP.stringify(cookie, false) == expected
        end

        cookies = [HTTP.Cookie("cookie-1", "v\$1"),
                   HTTP.Cookie("cookie-2", "v\$2"),
                   HTTP.Cookie("cookie-3", "v\$3"),
                  ]
        expected = "cookie-1=v\$1; cookie-2=v\$2; cookie-3=v\$3"
        @test HTTP.stringify("", cookies) == expected

        @testset "combine cookies with existing header" begin
            @test HTTP.stringify("cookie-0", cookies) == "cookie-0; $expected"
            @test HTTP.stringify("cookie-0=", cookies) == "cookie-0=; $expected"
            @test HTTP.stringify("cookie-0=0", cookies) == "cookie-0=0; $expected"
            @test HTTP.stringify("cookie-0=0 ", cookies) == "cookie-0=0 ; $expected"
            @test HTTP.stringify("cookie-0=0  ", cookies) == "cookie-0=0  ; $expected"
            @test HTTP.stringify("cookie-0=0;", cookies) == "cookie-0=0; $expected"
            @test HTTP.stringify("cookie-0=0; ", cookies) == "cookie-0=0; $expected"
            @test HTTP.stringify("cookie-0=0;  ", cookies) == "cookie-0=0;  $expected"
        end
    end

    @testset "readsetcookies" begin
        cookietests = [
            (["Set-Cookie" => "Cookie-1=v\$1"], [HTTP.Cookie("Cookie-1", "v\$1")]),
            (["Set-Cookie" => "NID=99=YsDT5i3E-CXax-; expires=Wed, 23-Nov-2011 01:05:03 GMT; path=/; domain=.google.ch; HttpOnly"],
            [HTTP.Cookie("NID", "99=YsDT5i3E-CXax-"; path="/", domain=".google.ch", httponly=true, expires=HTTP.Dates.DateTime(2011, 11, 23, 1, 5, 3, 0))]),
            (["Set-Cookie" => "NID=99=YsDT5i3E-CXax-; expires=Wed, 23 Nov 2011 01:05:03 GMT; path=/; domain=.google.ch; HttpOnly"],
            [HTTP.Cookie("NID", "99=YsDT5i3E-CXax-"; path="/", domain=".google.ch", httponly=true, expires=HTTP.Dates.DateTime(2011, 11, 23, 1, 5, 3, 0))]),
            (["Set-Cookie" => ".ASPXAUTH=7E3AA; expires=Wed, 07-Mar-2012 14:25:06 GMT; path=/; HttpOnly"],
            [HTTP.Cookie(".ASPXAUTH", "7E3AA"; path="/", expires=HTTP.Dates.DateTime(2012, 3, 7, 14, 25, 6, 0), httponly=true)]),
            (["Set-Cookie" => ".ASPXAUTH=7E3AA; expires=Wed, 07 Mar 2012 14:25:06 GMT; path=/; HttpOnly"],
            [HTTP.Cookie(".ASPXAUTH", "7E3AA"; path="/", expires=HTTP.Dates.DateTime(2012, 3, 7, 14, 25, 6, 0), httponly=true)]),
            (["Set-Cookie" => "ASP.NET_SessionId=foo; path=/; HttpOnly"],
            [HTTP.Cookie("ASP.NET_SessionId", "foo"; path="/", httponly=true)]),
            (["Set-Cookie" => "samesitedefault=foo; SameSite"], [HTTP.Cookie("samesitedefault", "foo"; samesite=HTTP.Cookies.SameSiteDefaultMode)]),
            (["Set-Cookie" => "samesiteinvalidisdefault=foo; SameSite=invalid"], [HTTP.Cookie("samesiteinvalidisdefault", "foo"; samesite=HTTP.Cookies.SameSiteDefaultMode)]),
            (["Set-Cookie" => "samesitelax=foo; SameSite=Lax"], [HTTP.Cookie("samesitelax", "foo"; samesite=HTTP.Cookies.SameSiteLaxMode)]),
            (["Set-Cookie" => "samesitestrict=foo; SameSite=Strict"], [HTTP.Cookie("samesitestrict", "foo"; samesite=HTTP.Cookies.SameSiteStrictMode)]),
            (["Set-Cookie" => "samesitenone=foo; SameSite=None"], [HTTP.Cookie("samesitenone", "foo"; samesite=HTTP.Cookies.SameSiteNoneMode)]),
            (["Set-Cookie" => "special-1=a z"],  [HTTP.Cookie("special-1", "a z")]),
            (["Set-Cookie" => "special-2=\" z\""], [HTTP.Cookie("special-2", " z")]),
            (["Set-Cookie" => "special-3=\"a \""], [HTTP.Cookie("special-3", "a ")]),
            (["Set-Cookie" => "special-4=\" \""],  [HTTP.Cookie("special-4", " ")]),
            (["Set-Cookie" => "special-5=a,z"],  [HTTP.Cookie("special-5", "a,z")]),
            (["Set-Cookie" => "special-6=\",z\""], [HTTP.Cookie("special-6", ",z")]),
            (["Set-Cookie" => "special-7=a,"],   [HTTP.Cookie("special-7", "a,")]),
            (["Set-Cookie" => "special-8=\",\""],  [HTTP.Cookie("special-8", ",")]),
        ]

        for (h, c) in cookietests
            @test HTTP.Cookies.readsetcookies(h) == c
        end
    end

    @testset "SetCookieDoubleQuotes" begin
        cookiestrings = [
            ["Set-Cookie" => "quoted0=none; max-age=30"],
            ["Set-Cookie" => "quoted1=\"cookieValue\"; max-age=31"],
            ["Set-Cookie" => "quoted2=cookieAV; max-age=\"32\""],
            ["Set-Cookie" => "quoted3=\"both\"; max-age=\"33\""],
        ]

        want = [
            [HTTP.Cookie("quoted0", "none", maxage=30)],
            [HTTP.Cookie("quoted1", "cookieValue", maxage=31)],
            [HTTP.Cookie("quoted2", "cookieAV")],
            [HTTP.Cookie("quoted3", "both")],
        ]
        @test all(HTTP.Cookies.readsetcookies.(cookiestrings) .== want)
    end

    @testset "Cookie sanitize value" begin
        values = Dict(
            "foo" => "foo",
            "foo;bar" => "foobar",
            "foo\\bar" => "foobar",
            "foo\"bar" => "foobar",
            String(UInt8[0x00, 0x7e, 0x7f, 0x80]) => String(UInt8[0x7e]),
            "\"withquotes\"" => "withquotes",
            "a z" => "\"a z\"",
            " z" => "\" z\"",
            "a " => "\"a \"",
            "a,z" => "\"a,z\"",
            ",z" => "\",z\"",
            "a," => "\"a,\"",
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

    @testset "Set-Cookie casing" begin
        server = HTTP.listen!(8080) do http
            t = http.message.target
            HTTP.setstatus(http, 200)
            if t == "/set-cookie"
                HTTP.setheader(http, "set-cookie" => "cookie=lc_cookie")
            elseif t == "/Set-Cookie"
                HTTP.setheader(http, "Set-Cookie" => "cookie=cc_cookie")
            elseif t == "/SET-COOKIE"
                HTTP.setheader(http, "SET-COOKIE" => "cookie=uc_cookie")
            elseif t == "/SeT-CooKiE"
                HTTP.setheader(http, "SeT-CooKiE" => "cookie=spongebob_cookie")
            elseif t =="/cookie"
                HTTP.setheader(http, "X-Cookie" => HTTP.header(http, "Cookie"))
            end
            HTTP.startwrite(http)
        end

        cookiejar = HTTP.Cookies.CookieJar()
        HTTP.get("http://localhost:8080/set-cookie"; cookies=true, cookiejar=cookiejar)
        r = HTTP.get("http://localhost:8080/cookie"; cookies=true, cookiejar=cookiejar)
        @test HTTP.header(r, "X-Cookie") == "cookie=lc_cookie"
        empty!(cookiejar)
        HTTP.get("http://localhost:8080/Set-Cookie"; cookies=true, cookiejar=cookiejar)
        r = HTTP.get("http://localhost:8080/cookie"; cookies=true, cookiejar=cookiejar)
        @test HTTP.header(r, "X-Cookie") == "cookie=cc_cookie"
        empty!(cookiejar)
        HTTP.get("http://localhost:8080/SET-COOKIE"; cookies=true, cookiejar=cookiejar)
        r = HTTP.get("http://localhost:8080/cookie"; cookies=true, cookiejar=cookiejar)
        @test HTTP.header(r, "X-Cookie") == "cookie=uc_cookie"
        empty!(cookiejar)
        HTTP.get("http://localhost:8080/SeT-CooKiE"; cookies=true, cookiejar=cookiejar)
        r = HTTP.get("http://localhost:8080/cookie"; cookies=true, cookiejar=cookiejar)
        @test HTTP.header(r, "X-Cookie") == "cookie=spongebob_cookie"
        close(server)
    end

    @testset "splithostport" begin
        testcases = [
        # Host name
        ("localhost:http", "localhost", "http"),
        ("localhost:80", "localhost", "80"),

        # Go-specific host name with zone identifier
        ("localhost%lo0:http", "localhost%lo0", "http"),
        ("localhost%lo0:80", "localhost%lo0", "80"),
        ("[localhost%lo0]:http", "localhost%lo0", "http"), # Go 1 behavior
        ("[localhost%lo0]:80", "localhost%lo0", "80"),     # Go 1 behavior

        # IP literal
        ("127.0.0.1:http", "127.0.0.1", "http"),
        ("127.0.0.1:80", "127.0.0.1", "80"),
        ("[::1]:http", "::1", "http"),
        ("[::1]:80", "::1", "80"),

        # IP literal with zone identifier
        ("[::1%lo0]:http", "::1%lo0", "http"),
        ("[::1%lo0]:80", "::1%lo0", "80"),

        # Go-specific wildcard for host name
        (":http", "", "http"), # Go 1 behavior
        (":80", "", "80"),     # Go 1 behavior

        # Go-specific wildcard for service name or transport port number
        ("golang.org:", "golang.org", ""), # Go 1 behavior
        ("127.0.0.1:", "127.0.0.1", ""),   # Go 1 behavior
        ("[::1]:", "::1", ""),             # Go 1 behavior

        # Opaque service name
        ("golang.org:https%foo", "golang.org", "https%foo"), # Go 1 behavior
        ]
        for (hostport, host, port) in testcases
            @test HTTP.Cookies.splithostport(hostport) == (host, port, false)
        end
        errorcases = [
            ("golang.org", "missing port in address"),
            ("127.0.0.1", "missing port in address"),
            ("[::1]", "missing port in address"),
            ("[fe80::1%lo0]", "missing port in address"),
            ("[localhost%lo0]", "missing port in address"),
            ("localhost%lo0", "missing port in address"),

            ("::1", "too many colons in address"),
            ("fe80::1%lo0", "too many colons in address"),
            ("fe80::1%lo0:80", "too many colons in address"),

            # Test cases that didn't fail in Go 1
            ("[foo:bar]", "missing port in address"),
            ("[foo:bar]baz", "missing port in address"),
            ("[foo]bar:baz", "missing port in address"),

            ("[foo]:[bar]:baz", "too many colons in address"),

            ("[foo]:[bar]baz", "unexpected '[' in address"),
            ("foo[bar]:baz", "unexpected '[' in address"),

            ("foo]bar:baz", "unexpected ']' in address"),
        ]
        for (hostport, err) in errorcases
            @test HTTP.Cookies.splithostport(hostport) == ("", "", true)
        end
    end

    @testset "addcookie!" begin
        r = HTTP.Request("GET", "/")
        c        = HTTP.Cookie("NID", "99=YsDT5i3E-CXax-"; path="/", domain=".google.ch", httponly=true, expires=HTTP.Dates.DateTime(2011, 11, 23, 1, 5, 3, 0))
        c_parsed = HTTP.Cookie("NID", "99=YsDT5i3E-CXax-"; path="/", domain="google.ch", httponly=true, expires=HTTP.Dates.DateTime(2011, 11, 23, 1, 5, 3, 0))
        HTTP.addcookie!(r, c)
        @test HTTP.header(r, "Cookie") == "NID=99=YsDT5i3E-CXax-"
        HTTP.addcookie!(r, c)
        @test HTTP.header(r, "Cookie") == "NID=99=YsDT5i3E-CXax-; NID=99=YsDT5i3E-CXax-"
        r = HTTP.Response(200)
        HTTP.addcookie!(r, c)
        @test HTTP.header(r, "Set-Cookie") == "NID=99=YsDT5i3E-CXax-; Path=/; Domain=google.ch; Expires=Wed, 23 Nov 2011 01:05:03 GMT; HttpOnly"
        @test [c_parsed] == HTTP.Cookies.readsetcookies(["Set-Cookie" => HTTP.header(r, "Set-Cookie")])
        HTTP.addcookie!(r, c)
        @test HTTP.headers(r, "Set-Cookie") == ["NID=99=YsDT5i3E-CXax-; Path=/; Domain=google.ch; Expires=Wed, 23 Nov 2011 01:05:03 GMT; HttpOnly", "NID=99=YsDT5i3E-CXax-; Path=/; Domain=google.ch; Expires=Wed, 23 Nov 2011 01:05:03 GMT; HttpOnly"]
        @test [c_parsed, c_parsed] == HTTP.Cookies.readsetcookies(["Set-Cookie"] .=> HTTP.headers(r, "Set-Cookie"))
    end
end

end # module
