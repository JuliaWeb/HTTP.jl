using Test
using HTTP
using Reseau

const HT = HTTP

function _set_cookie_headers(values::AbstractString...)::HT.Headers
    headers = HT.Headers()
    for value in values
        HT.appendheader(headers, "Set-Cookie", value)
    end
    return headers
end

@testset "HTTP cookie parsing and stringifying" begin
    headers = _set_cookie_headers("sid=abc; Path=/; Domain=.example.com; Max-Age=60; HttpOnly; Secure; SameSite=Lax")
    response = HT.Response(200; headers = headers)
    parsed = HT.cookies(response)
    @test length(parsed) == 1
    cookie = parsed[1]
    @test cookie.name == "sid"
    @test cookie.value == "abc"
    @test cookie.path == "/"
    @test cookie.domain == ".example.com"
    @test cookie.maxage == 60
    @test cookie.httponly
    @test cookie.secure
    @test cookie.samesite == HT.Cookies.SameSiteLaxMode
    rendered = HT.stringify(cookie, false)
    @test occursin("sid=abc", rendered)
    @test occursin("; Path=/", rendered)
    @test occursin("; Domain=example.com", rendered)
    @test occursin("; Max-Age=60", rendered)
    @test occursin("; HttpOnly", rendered)
    @test occursin("; Secure", rendered)
    @test occursin("; SameSite=Lax", rendered)

    req_headers = HT.Headers()
    HT.appendheader(req_headers, "Cookie", "a=1; b=two")
    request = HT.Request("GET", "/"; headers = req_headers)
    req_cookies = HT.cookies(request)
    @test [(c.name, c.value) for c in req_cookies] == [("a", "1"), ("b", "two")]

    strict_cookie = HT.Cookie("strict", "v"; samesite = HT.Cookies.SameSiteStrictMode)
    none_cookie = HT.Cookie("none", "v"; samesite = HT.Cookies.SameSiteNoneMode)
    @test occursin("; SameSite=Strict", HT.stringify(strict_cookie, false))
    @test occursin("; SameSite=None", HT.stringify(none_cookie, false))

    # SameSite enum values are re-exported at top level
    @test HT.SameSiteDefaultMode === HT.Cookies.SameSiteDefaultMode
    @test HT.SameSiteLaxMode === HT.Cookies.SameSiteLaxMode
    @test HT.SameSiteStrictMode === HT.Cookies.SameSiteStrictMode
    @test HT.SameSiteNoneMode === HT.Cookies.SameSiteNoneMode
    top_level_cookie = HT.Cookie("session", "abc"; samesite = HT.SameSiteStrictMode)
    @test occursin("; SameSite=Strict", HT.stringify(top_level_cookie, false))

    # Symbol shorthand maps to enum constants
    @test HT.Cookie("a", "1"; samesite = :strict).samesite == HT.SameSiteStrictMode
    @test HT.Cookie("a", "1"; samesite = :lax).samesite == HT.SameSiteLaxMode
    @test HT.Cookie("a", "1"; samesite = :none).samesite == HT.SameSiteNoneMode
    @test HT.Cookie("a", "1"; samesite = :default).samesite == HT.SameSiteDefaultMode
    @test_throws ArgumentError HT.Cookie("a", "1"; samesite = :bogus)

    @test HT.stringify("a=1;", [HT.Cookie("b", "2")]) == "a=1; b=2"
    @test HT.stringify("a=1", [HT.Cookie("b", "2")]) == "a=1; b=2"

    parsed_extra = HT.Cookies.readsetcookies(_set_cookie_headers(
        "strict=1; SameSite=Strict",
        "none=1; SameSite=None",
        "default=1; SameSite=Unknown",
        "quoted=\"ok\"; Foo=ba\\d",
        "tokenonly; Path=/solo",
        "leading=1; Max-Age=01",
    ))
    @test [cookie.name for cookie in parsed_extra] == ["strict", "none", "default", "quoted", "tokenonly", "leading"]
    @test parsed_extra[1].samesite == HT.Cookies.SameSiteStrictMode
    @test parsed_extra[2].samesite == HT.Cookies.SameSiteNoneMode
    @test parsed_extra[3].samesite == HT.Cookies.SameSiteDefaultMode
    @test parsed_extra[4].value == "ok"
    @test parsed_extra[4].unparsed == ["Foo=ba\\d"]
    @test parsed_extra[5].value == ""
    @test parsed_extra[5].path == "/solo"
    @test parsed_extra[6].maxage == 0
end

@testset "HTTP addcookie! appends request and response headers" begin
    request = HT.Request("GET", "/")
    HT.addcookie!(request, HT.Cookie("session", "abc"))
    @test HT.headers(request.headers, "Cookie") == ["session=abc"]

    response = HT.Response(200)
    HT.addcookie!(response, HT.Cookie("session", "abc"; path = "/", secure = true))
    values = HT.headers(response.headers, "Set-Cookie")
    @test length(values) == 1
    @test occursin("session=abc", values[1])
    @test occursin("; Path=/", values[1])
    @test occursin("; Secure", values[1])
end

@testset "HTTP CookieJar matches host, path, secure, and delete semantics" begin
    jar = HT.CookieJar()
    headers = _set_cookie_headers(
        "root=1; Path=/",
        "docs=2; Path=/docs",
        "domainwide=3; Domain=.example.com; Path=/",
        "secureonly=4; Path=/; Secure",
        "auto=5",
    )
    HT.setcookies!(jar, "https", "example.com", "/docs/index", headers)

    cookies_https = HT.getcookies!(jar, "https", "example.com", "/docs/page")
    names_https = [c.name for c in cookies_https]
    @test "docs" in names_https
    @test "root" in names_https
    @test "domainwide" in names_https
    @test "secureonly" in names_https
    @test "auto" in names_https
    @test Set(names_https[1:2]) == Set(["auto", "docs"])

    cookies_http = HT.getcookies!(jar, "http", "example.com", "/docs/page")
    @test !("secureonly" in [c.name for c in cookies_http])

    cookies_subdomain = HT.getcookies!(jar, "https", "api.example.com", "/")
    names_subdomain = [c.name for c in cookies_subdomain]
    @test "domainwide" in names_subdomain
    @test !("root" in names_subdomain)
    @test !("auto" in names_subdomain)

    delete_headers = _set_cookie_headers("root=gone; Path=/; Max-Age=-1")
    HT.setcookies!(jar, "https", "example.com", "/docs/index", delete_headers)
    @test !("root" in [c.name for c in HT.getcookies!(jar, "https", "example.com", "/docs/page")])

    expired_headers = _set_cookie_headers("expired=old; Path=/; Expires=Wed, 23-Nov-2011 01:05:03 GMT")
    HT.setcookies!(jar, "https", "example.com", "/docs/index", expired_headers)
    @test !("expired" in [c.name for c in HT.getcookies!(jar, "https", "example.com", "/docs/page")])
end

@testset "HTTP CookieJar restores from saved entries (#931)" begin
    # "save": populate a jar, then keep its entries storage
    jar = HT.CookieJar()
    headers = _set_cookie_headers("session=abc; Path=/", "theme=dark; Path=/")
    HT.setcookies!(jar, "https", "example.com", "/", headers)
    saved = jar.entries
    # "load": a jar prepopulated from saved entries serves the same cookies
    restored = HT.CookieJar(saved)
    names = sort([c.name for c in HT.getcookies!(restored, "https", "example.com", "/")])
    @test names == ["session", "theme"]
    # and keeps applying normal jar semantics for later updates
    delete_headers = _set_cookie_headers("session=gone; Path=/; Max-Age=-1")
    HT.setcookies!(restored, "https", "example.com", "/", delete_headers)
    @test [c.name for c in HT.getcookies!(restored, "https", "example.com", "/")] == ["theme"]
end

@testset "HTTP cookie helper validation and canonicalization" begin
    headers = HT.Headers()
    HT.appendheader(headers, "Cookie", "flag; named=value")
    parsed = HT.Cookies.readcookies(headers)
    @test [(cookie.name, cookie.value) for cookie in parsed] == [("flag", ""), ("named", "value")]

    @test HT.Cookies.validCookieDomain("example.com")
    @test HT.Cookies.validCookieDomain(".example.com")
    @test HT.Cookies.validCookieDomain("127.0.0.1")
    @test !HT.Cookies.validCookieDomain("2001:db8::1")
    @test !HT.Cookies.validCookieDomain("-bad.example")
    @test !HT.Cookies.isCookieDomainName("bad..example")
    @test !HT.Cookies.isCookieDomainName(string(repeat("a", 64), ".example.com"))

    @test HT.Cookies.sanitizeCookieValue("hello") == "hello"
    @test HT.Cookies.sanitizeCookieValue("a b,c") == "\"a b,c\""
    @test HT.Cookies.sanitizeCookieValue("bad;\nvalue") == "badvalue"

    @test HT.Cookies.hasport("example.com:443")
    @test HT.Cookies.hasport("[::1]:443")
    @test !HT.Cookies.hasport("example.com")
    @test !HT.Cookies.hasport("[::1]")
    @test HT.Cookies.canonicalhost("Example.com.:443") == "example.com"
    @test HT.Cookies.canonicalhost("exämple.com") == ""
    @test HT.Cookies.defaultPath("") == "/"
    @test HT.Cookies.defaultPath("relative") == "/"
    @test HT.Cookies.defaultPath("/file") == "/"
    @test HT.Cookies.defaultPath("/dir/file") == "/dir"

    @test HT.Cookies.splithostport("example.com:443") == ("example.com", "443", false)
    for hostport in ("example.com", "[::1]:443", "[::1]", "example.com:80:90", "[::1", "[::1]:80:90")
        host, port, err = HT.Cookies.splithostport(hostport)
        @test host == ""
        @test port == ""
        @test err
    end

    @test HT.Cookies.pathmatch(HT.Cookie("docs", "1"; path = "/docs"), "/docs/page")
    @test HT.Cookies.pathmatch(HT.Cookie("docs", "1"; path = "/docs/"), "/docs/page")
    @test !HT.Cookies.pathmatch(HT.Cookie("docs", "1"; path = "/docs"), "/docset")
end

@testset "HTTP CookieJar domain normalization helpers" begin
    jar = HT.CookieJar()

    hostonly = HT.Cookie("hostonly", "1")
    @test HT.Cookies.domainAndType!(jar, hostonly, "example.com")
    @test hostonly.hostonly
    @test hostonly.domain == "example.com"

    shared = HT.Cookie("shared", "1"; domain = ".Example.COM")
    @test HT.Cookies.domainAndType!(jar, shared, "api.example.com")
    @test !shared.hostonly
    @test shared.domain == "example.com"

    bad_ip = HT.Cookie("bad-ip", "1"; domain = "10.0.0.2")
    @test !HT.Cookies.domainAndType!(jar, bad_ip, "10.0.0.1")
    @test bad_ip.domain == ""
    @test !bad_ip.hostonly

    bad_suffix = HT.Cookie("bad-suffix", "1"; domain = "other.com")
    @test !HT.Cookies.domainAndType!(jar, bad_suffix, "example.com")
    @test bad_suffix.domain == ""

    bad_unicode = HT.Cookie("bad-unicode", "1"; domain = "exämple.com")
    @test !HT.Cookies.domainAndType!(jar, bad_unicode, "example.com")
    @test bad_unicode.domain == ""

    bad_trailing = HT.Cookie("bad-trailing", "1"; domain = "example.com.")
    @test !HT.Cookies.domainAndType!(jar, bad_trailing, "example.com")
    @test bad_trailing.domain == ""

    seeded = _set_cookie_headers("remember=1; Domain=.Example.com; Path=/docs")
    HT.setcookies!(jar, "https", "Example.com.:443", "/docs/page", seeded)
    stored = HT.getcookies!(jar, "https", "example.com", "/docs/page")
    @test [cookie.name for cookie in stored] == ["remember"]
    remember_id = HT.Cookies.id(stored[1])
    key = HT.Cookies.jarKey("example.com")
    old_creation = HT.Cookies.Dates.DateTime(2020, 1, 1)
    Base.@lock jar.lock begin
        jar.entries[key][remember_id].creation = old_creation
    end

    update = _set_cookie_headers("remember=2; Domain=.example.com; Path=/docs")
    HT.setcookies!(jar, "https", "example.com", "/docs/page", update)
    refreshed = only(HT.getcookies!(jar, "https", "example.com", "/docs/page"))
    @test refreshed.value == "2"
    @test refreshed.creation == old_creation

    stale = HT.Cookie("stale", "1"; domain = "example.com", path = "/")
    stale.persistent = true
    stale.expires = HT.Cookies.Dates.now(HT.Cookies.Dates.UTC) - HT.Cookies.Dates.Second(1)
    stale.creation = old_creation
    stale.lastaccess = old_creation
    Base.@lock jar.lock begin
        jar.entries[key][HT.Cookies.id(stale)] = stale
    end
    cookies = HT.getcookies!(jar, "https", "example.com", "/")
    @test !any(cookie -> cookie.name == "stale", cookies)
    @test !haskey(jar.entries[key], HT.Cookies.id(stale))
end

@testset "_cookie_header merges a manual Cookie header (de-duped by name)" begin
    host = "h.example.com"

    # Serialize → parse back into (name, value) pairs using the library's own reader.
    function _pairs(hdr)
        hdr === nothing && return Tuple{String,String}[]
        h = HT.Headers()
        HT.appendheader(h, "Cookie", hdr)
        return [(c.name, c.value) for c in HT.cookies(HT.Request("GET", "/"; headers = h))]
    end

    # Build a jar from (request-path => Set-Cookie) specs.
    function seed(specs...)
        jar = HT.CookieJar()
        for (p, sc) in specs
            HT.setcookies!(jar, "https", host, p, _set_cookie_headers(sc))
        end
        return jar
    end

    # cookies=false: the cookie layer must leave a manual header untouched.
    @test HT._cookie_header(seed("/" => "sid=JAR; Path=/"), false, true, host, "/",
                            [HT.Cookie("sid", "MANUAL")]) === nothing

    # No jar, cookies=true: a manual header flows through unchanged.
    @test _pairs(HT._cookie_header(nothing, true, true, host, "/",
                                   [HT.Cookie("a", "1")])) == [("a", "1")]

    # Duplicate names within the manual header collapse to the first occurrence.
    @test _pairs(HT._cookie_header(nothing, true, true, host, "/",
                                   [HT.Cookie("a", "1"), HT.Cookie("a", "2")])) == [("a", "1")]

    # Disjoint names: jar and manual cookies are both sent.
    p = _pairs(HT._cookie_header(seed("/" => "sid=JAR; Path=/"), true, true, host, "/",
                                 [HT.Cookie("extra", "M")]))
    @test ("sid", "JAR") in p && ("extra", "M") in p

    # Same name: the managed (jar) cookie wins, the manual one is dropped, no duplicate.
    @test _pairs(HT._cookie_header(seed("/" => "sid=JAR; Path=/"), true, true, host, "/",
                                   [HT.Cookie("sid", "MANUAL")])) == [("sid", "JAR")]

    # An explicit `cookies=` dict also wins over the manual header, by name.
    p = _pairs(HT._cookie_header(seed("/" => "sid=JAR; Path=/"), [HT.Cookie("d", "1")],
                                 true, host, "/", [HT.Cookie("sid", "X"), HT.Cookie("d", "X")]))
    @test ("sid", "JAR") in p && ("d", "1") in p && !any(t -> t[2] == "X", p)

    # Path-scoped same-name cookies in the jar (e.g. one2team's two JSESSIONIDs) are both
    # preserved; a manual cookie of that name is dropped rather than shadowing either.
    jar = seed("/" => "JSESSIONID=ROOT; Path=/", "/app" => "JSESSIONID=APP; Path=/app")
    p = _pairs(HT._cookie_header(jar, true, true, host, "/app/page",
                                 [HT.Cookie("JSESSIONID", "MANUAL")]))
    jsess = [v for (n, v) in p if n == "JSESSIONID"]
    @test Set(jsess) == Set(["ROOT", "APP"])
    @test !("MANUAL" in jsess)
end

@testset "HTTP cookie name chars above ASCII 119 regression (BoundsError fix)" begin
    # Regression test: the old normal_url_char table had only 120 entries, so any
    # cookie name containing a char with codepoint >= 120 (x, y, z, {, |, }, ~)
    # caused a BoundsError inside isurlchar, silently dropping the cookie.
    # The table was also missing the 112–119 row, shifting the final row up so
    # that 'w' (codepoint 119) was mapped to the DEL entry (false), causing
    # cookies named e.g. "w" to be silently dropped too.
    isurlchar = HTTP.Cookies.isurlchar
    @test isurlchar('w') && isurlchar('{') && isurlchar('|') && isurlchar('}') && !isurlchar('\x7f')

    jar = HT.CookieJar()

    # xsrf_token: name contains 'x' (codepoint 120) — previously threw BoundsError
    headers = _set_cookie_headers("xsrf_token=abc123; Path=/")
    HT.setcookies!(jar, "https", "example.com", "/", headers)
    stored = HT.getcookies!(jar, "https", "example.com", "/")
    names = [c.name for c in stored]
    @test "xsrf_token" in names
    xsrf = stored[findfirst(c -> c.name == "xsrf_token", stored)]
    @test xsrf.value == "abc123"

    # Cookie names that are single chars in the formerly-broken range
    for ch in ('x', 'y', 'z', '{', '|', '}', '~', 'w')
        jar2 = HT.CookieJar()
        HT.setcookies!(jar2, "https", "example.com", "/",
            _set_cookie_headers("$(ch)=1; Path=/"))
        got = HT.getcookies!(jar2, "https", "example.com", "/")
        @test length(got) == 1
        @test got[1].name == string(ch)
    end
end
