type URLTest
    name::String
    url::String
    isconnect::Bool
    offsets::NTuple{7, HTTP.Offset}
    shouldthrow::Bool
end

URLTest(nm::String, url::String, isconnect::Bool, shouldthrow::Bool) = URLTest(nm, url, isconnect, ntuple(x->HTTP.Offset(), 7), shouldthrow)

@testset "HTTP.URI" begin
    urls = ["hdfs://user:password@hdfshost:9000/root/folder/file.csv#frag",
        "https://user:password@httphost:9000/path1/path2;paramstring?q=a&p=r#frag",
        "https://user:password@httphost:9000/path1/path2?q=a&p=r#frag",
        "https://user:password@httphost:9000/path1/path2;paramstring#frag",
        "https://user:password@httphost:9000/path1/path2#frag",
        "file:///path/to/file/with%3fshould%3dwork%23fine",
        "ftp://ftp.is.co.za/rfc/rfc1808.txt", "http://www.ietf.org/rfc/rfc2396.txt",
        "ldap://[2001:db8::7]/c=GB?objectClass?one", "mailto:John.Doe@example.com",
        "news:comp.infosystems.www.servers.unix", "tel:+1-816-555-1212", "telnet://192.0.2.16:80/",
        "urn:oasis:names:specification:docbook:dtd:xml:4.1.2"]

    for url in urls
        u = parse(HTTP.URI, url)
        @test string(u) == url
        @test isvalid(u)
    end

    @test parse(HTTP.URI, "hdfs://user:password@hdfshost:9000/root/folder/file.csv") == HTTP.URI("hdfshost", "/root/folder/file.csv"; scheme="hdfs", port=9000, userinfo="user:password")
    @test parse(HTTP.URI, "http://google.com:80/some/path") == HTTP.URI("google.com", "/some/path")

    @test HTTP.escape("abcdef αβ 1234-=~!@#\$()_+{}|[]a;") == "abcdef%20%CE%B1%CE%B2%201234-%3D~%21%40%23%24%28%29_%2B%7B%7D%7C%5B%5Da%3B"
    @test HTTP.unescape(HTTP.escape("abcdef 1234-=~!@#\$()_+{}|[]a;")) == "abcdef 1234-=~!@#\$()_+{}|[]a;"
    @test HTTP.unescape(HTTP.escape("👽")) == "👽"

    @test "user:password" == HTTP.userinfo(parse(HTTP.URI, "https://user:password@httphost:9000/path1/path2;paramstring?q=a&p=r#frag"))

    # @test ["dc","example","dc","com"] == HTTP.path_params(HTTP.URI("ldap://ldap.example.com/dc=example,dc=com"))[1]
    # @test ["servlet","jsessionid","OI24B9ASD7BSSD"] == HTTP.path_params(HTTP.URI("http://www.mysite.com/servlet;jsessionid=OI24B9ASD7BSSD"))[1]

    # @test Dict("q"=>"a","p"=>"r") == HTTP.query_params(HTTP.URI("https://httphost/path1/path2;paramstring?q=a&p=r#frag"))
    # @test Dict("q"=>"a","malformed"=>"") == HTTP.query_params(HTTP.URI("https://foo.net/?q=a&malformed"))

    @test false == isvalid(parse(HTTP.URI, "file:///path/to/file/with?should=work#fine"))
    @test true == isvalid( parse(HTTP.URI, "file:///path/to/file/with%3fshould%3dwork%23fine"))

    @test parse(HTTP.URI, "s3://bucket/key") == HTTP.URI("bucket", "/key"; scheme="s3")

    @test sprint(show, parse(HTTP.URI, "http://google.com")) == "HTTP.URI(\"http://google.com\")"

    # Error paths
    # Non-ASCII characters
    @test_throws HTTP.ParsingError parse(HTTP.URI, "http://🍕.com")
    # Unexpected start of URL
    @test_throws HTTP.ParsingError parse(HTTP.URI, ".google.com")
    # Unexpected character after scheme
    @test_throws HTTP.ParsingError parse(HTTP.URI, "ht!tp://google.com")

    #  Issue #27
    @test HTTP.escape("t est\n") == "t%20est%0A"

    @testset "HTTP.parse(HTTP.URI, str)" begin

        const urltests = URLTest[
        URLTest("proxy request"
         ,"http://hostname/"
         ,false
             ,(HTTP.Offset(1, 4) # UF_SCHEMA
             ,HTTP.Offset(8, 8) # UF_HOST
             ,HTTP.Offset(0, 0) # UF_PORT
             ,HTTP.Offset(16, 1) # UF_PATH
             ,HTTP.Offset(0, 0) # UF_QUERY
             ,HTTP.Offset(0, 0) # UF_FRAGMENT
             ,HTTP.Offset(0, 0) # UF_USERINFO
             )
         ,false
         ), URLTest("proxy request with port"
         ,"http://hostname:444/"
         ,false
             ,(HTTP.Offset(1, 4) # UF_SCHEMA
             ,HTTP.Offset(8, 8) # UF_HOST
             ,HTTP.Offset(17, 3) # UF_PORT
             ,HTTP.Offset(20, 1) # UF_PATH
             ,HTTP.Offset(0, 0) # UF_QUERY
             ,HTTP.Offset(0, 0) # UF_FRAGMENT
             ,HTTP.Offset(0, 0) # UF_USERINFO
             )
         ,false
         ), URLTest("CONNECT request"
         ,"hostname:443"
         ,true
             ,(HTTP.Offset(0, 0) # UF_SCHEMA
             ,HTTP.Offset(1, 8) # UF_HOST
             ,HTTP.Offset(10, 3) # UF_PORT
             ,HTTP.Offset(0, 0) # UF_PATH
             ,HTTP.Offset(0, 0) # UF_QUERY
             ,HTTP.Offset(0, 0) # UF_FRAGMENT
             ,HTTP.Offset(0, 0) # UF_USERINFO
             )
         ,false
         ), URLTest("proxy ipv6 request"
         ,"http://[1:2::3:4]/"
         ,false
             ,(HTTP.Offset(1, 4) # UF_SCHEMA
             ,HTTP.Offset(9, 8) # UF_HOST
             ,HTTP.Offset(0, 0) # UF_PORT
             ,HTTP.Offset(18, 1) # UF_PATH
             ,HTTP.Offset(0, 0) # UF_QUERY
             ,HTTP.Offset(0, 0) # UF_FRAGMENT
             ,HTTP.Offset(0, 0) # UF_USERINFO
             )
         ,false
         ), URLTest("proxy ipv6 request with port"
         ,"http://[1:2::3:4]:67/"
         ,false
             ,(HTTP.Offset(1, 4) # UF_SCHEMA
             ,HTTP.Offset(9, 8) # UF_HOST
             ,HTTP.Offset(19, 2) # UF_PORT
             ,HTTP.Offset(21, 1) # UF_PATH
             ,HTTP.Offset(0, 0) # UF_QUERY
             ,HTTP.Offset(0, 0) # UF_FRAGMENT
             ,HTTP.Offset(0, 0) # UF_USERINFO
             )
         ,false
         ), URLTest("CONNECT ipv6 address"
         ,"[1:2::3:4]:443"
         ,true
             ,(HTTP.Offset(0, 0) # UF_SCHEMA
             ,HTTP.Offset(2, 8) # UF_HOST
             ,HTTP.Offset(12, 3) # UF_PORT
             ,HTTP.Offset(0, 0) # UF_PATH
             ,HTTP.Offset(0, 0) # UF_QUERY
             ,HTTP.Offset(0, 0) # UF_FRAGMENT
             ,HTTP.Offset(0, 0) # UF_USERINFO
             )
         ,false
         ), URLTest("ipv4 in ipv6 address"
         ,"http://[2001:0000:0000:0000:0000:0000:1.9.1.1]/"
         ,false
             ,(HTTP.Offset(1, 4) # UF_SCHEMA
             ,HTTP.Offset(9,37) # UF_HOST
             ,HTTP.Offset(0, 0) # UF_PORT
             ,HTTP.Offset(47, 1) # UF_PATH
             ,HTTP.Offset(0, 0) # UF_QUERY
             ,HTTP.Offset(0, 0) # UF_FRAGMENT
             ,HTTP.Offset(0, 0) # UF_USERINFO
             )
         ,false
         ), URLTest("extra ? in query string"
         ,"http://a.tbcdn.cn/p/fp/2010c/??fp-header-min.css,fp-base-min.css,fp-channel-min.css,fp-product-min.css,fp-mall-min.css,fp-category-min.css,fp-sub-min.css,fp-gdp4p-min.css,fp-css3-min.css,fp-misc-min.css?t=20101022.css"
         ,false
             ,(HTTP.Offset(1, 4) # UF_SCHEMA
             ,HTTP.Offset(8,10) # UF_HOST
             ,HTTP.Offset(0, 0) # UF_PORT
             ,HTTP.Offset(18,12) # UF_PATH
             ,HTTP.Offset(31,187) # UF_QUERY
             ,HTTP.Offset(0, 0) # UF_FRAGMENT
             ,HTTP.Offset(0, 0) # UF_USERINFO
             )
         ,false
         ), URLTest("space URL encoded"
         ,"/toto.html?toto=a%20b"
         ,false
             ,(HTTP.Offset(0, 0) # UF_SCHEMA
             ,HTTP.Offset(0, 0) # UF_HOST
             ,HTTP.Offset(0, 0) # UF_PORT
             ,HTTP.Offset(1,10) # UF_PATH
             ,HTTP.Offset(12,10) # UF_QUERY
             ,HTTP.Offset(0, 0) # UF_FRAGMENT
             ,HTTP.Offset(0, 0) # UF_USERINFO
             )
         ,false
         ), URLTest("URL fragment"
         ,"/toto.html#titi"
         ,false
             ,(HTTP.Offset(0, 0) # UF_SCHEMA
             ,HTTP.Offset(0, 0) # UF_HOST
             ,HTTP.Offset(0, 0) # UF_PORT
             ,HTTP.Offset(1,10) # UF_PATH
             ,HTTP.Offset(0, 0) # UF_QUERY
             ,HTTP.Offset(12, 4) # UF_FRAGMENT
             ,HTTP.Offset(0, 0) # UF_USERINFO
             )
         ,false
         ), URLTest("complex URL fragment"
         ,"http://www.webmasterworld.com/r.cgi?f=21&d=8405&url=http://www.example.com/index.html?foo=bar&hello=world#midpage"
         ,false
         ,(HTTP.Offset(  1,  4) # UF_SCHEMA
          ,HTTP.Offset(  8, 22) # UF_HOST
          ,HTTP.Offset(  0,  0) # UF_PORT
          ,HTTP.Offset( 30,  6) # UF_PATH
          ,HTTP.Offset( 37, 69) # UF_QUERY
          ,HTTP.Offset(107,  7) # UF_FRAGMENT
          ,HTTP.Offset(  0,  0) # UF_USERINFO
          )
         ,false
         ), URLTest("complex URL from node js url parser doc"
         ,"http://host.com:8080/p/a/t/h?query=string#hash"
         ,false
         ,(   HTTP.Offset(1, 4) # UF_SCHEMA
             ,HTTP.Offset(8, 8) # UF_HOST
             ,HTTP.Offset(17, 4) # UF_PORT
             ,HTTP.Offset(21, 8) # UF_PATH
             ,HTTP.Offset(30,12) # UF_QUERY
             ,HTTP.Offset(43, 4) # UF_FRAGMENT
             ,HTTP.Offset(0, 0) # UF_USERINFO
             )
             ,false
         ), URLTest("complex URL with basic auth from node js url parser doc"
         ,"http://a:b@host.com:8080/p/a/t/h?query=string#hash"
         ,false
         ,(   HTTP.Offset(1, 4) # UF_SCHEMA
             ,HTTP.Offset(12, 8) # UF_HOST
             ,HTTP.Offset(21, 4) # UF_PORT
             ,HTTP.Offset(25, 8) # UF_PATH
             ,HTTP.Offset(34,12) # UF_QUERY
             ,HTTP.Offset(47, 4) # UF_FRAGMENT
             ,HTTP.Offset(8, 3) # UF_USERINFO
             )
            ,false
         ), URLTest("double @"
         ,"http://a:b@@hostname:443/"
         ,false
         ,true
         ), URLTest("proxy empty host"
         ,"http://:443/"
         ,false
         ,true
         ), URLTest("proxy empty port"
         ,"http://hostname:/"
         ,false
         ,true
         ), URLTest("CONNECT with basic auth"
         ,"a:b@hostname:443"
         ,true
         ,true
         ), URLTest("CONNECT empty host"
         ,":443"
         ,true
         ,true
         ), URLTest("CONNECT empty port"
         ,"hostname:"
         ,true
         ,true
         ), URLTest("CONNECT with extra bits"
         ,"hostname:443/"
         ,true
         ,true
         ), URLTest("space in URL"
         ,"/foo bar/"
         ,false
         ,true # s_dead
         ), URLTest("proxy basic auth with space url encoded"
         ,"http://a%20:b@host.com/"
         ,false
             ,(HTTP.Offset(1, 4) # UF_SCHEMA
              ,HTTP.Offset(15, 8) # UF_HOST
              ,HTTP.Offset(0, 0) # UF_PORT
              ,HTTP.Offset(23, 1) # UF_PATH
              ,HTTP.Offset(0, 0) # UF_QUERY
              ,HTTP.Offset(0, 0) # UF_FRAGMENT
              ,HTTP.Offset(8, 6) # UF_USERINFO
             )
         ,false
         ), URLTest("carriage return in URL"
         ,"/foo\rbar/"
         ,false
         ,true # s_dead
         ), URLTest("proxy double : in URL"
         ,"http://hostname::443/"
         ,false
         ,true # s_dead
         ), URLTest("proxy basic auth with double :"
         ,"http://a::b@host.com/"
         ,false
             ,(HTTP.Offset(1, 4) # UF_SCHEMA
             ,HTTP.Offset(13, 8) # UF_HOST
             ,HTTP.Offset(0, 0) # UF_PORT
             ,HTTP.Offset(21, 1) # UF_PATH
             ,HTTP.Offset(0, 0) # UF_QUERY
             ,HTTP.Offset(0, 0) # UF_FRAGMENT
             ,HTTP.Offset(8, 4) # UF_USERINFO
             )
         ,false
         ), URLTest("line feed in URL"
         ,"/foo\nbar/"
         ,false
         ,true # s_dead
         ), URLTest("proxy empty basic auth"
         ,"http://@hostname/fo"
         ,false
             ,(HTTP.Offset(1, 4) # UF_SCHEMA
             ,HTTP.Offset(9, 8) # UF_HOST
             ,HTTP.Offset(0, 0) # UF_PORT
             ,HTTP.Offset(17, 3) # UF_PATH
             ,HTTP.Offset(0, 0) # UF_QUERY
             ,HTTP.Offset(0, 0) # UF_FRAGMENT
             ,HTTP.Offset(0, 0) # UF_USERINFO
             )
         ,false
         ), URLTest("proxy line feed in hostname"
         ,"http://host\name/fo"
         ,false
         ,true # s_dead
         ), URLTest("proxy % in hostname"
         ,"http://host%name/fo"
         ,false
         ,true # s_dead
         ), URLTest("proxy ; in hostname"
         ,"http://host;ame/fo"
         ,false
         ,true # s_dead
         ), URLTest("proxy basic auth with unreservedchars"
         ,"http://a!;-_!=+\$@host.com/"
         ,false
             ,(HTTP.Offset(1, 4) # UF_SCHEMA
             ,HTTP.Offset(18, 8) # UF_HOST
             ,HTTP.Offset(0, 0) # UF_PORT
             ,HTTP.Offset(26, 1) # UF_PATH
             ,HTTP.Offset(0, 0) # UF_QUERY
             ,HTTP.Offset(0, 0) # UF_FRAGMENT
             ,HTTP.Offset(8, 9) # UF_USERINFO
             )
         ,false
         ), URLTest("proxy only empty basic auth"
         ,"http://@/fo"
         ,false
         ,true # s_dead
         ), URLTest("proxy only basic auth"
         ,"http://toto@/fo"
         ,false
         ,true # s_dead
         ), URLTest("proxy = in URL"
         ,"http://host=ame/fo"
         ,false
         ,true # s_dead
         ), URLTest("ipv6 address with Zone ID"
         ,"http://[fe80::a%25eth0]/"
         ,false
             ,(HTTP.Offset(1, 4) # UF_SCHEMA
             ,HTTP.Offset(9,14) # UF_HOST
             ,HTTP.Offset(0, 0) # UF_PORT
             ,HTTP.Offset(24, 1) # UF_PATH
             ,HTTP.Offset(0, 0) # UF_QUERY
             ,HTTP.Offset(0, 0) # UF_FRAGMENT
             ,HTTP.Offset(0, 0) # UF_USERINFO
             )
         ,false
         ), URLTest("ipv6 address with Zone ID, but '%' is not percent-encoded"
         ,"http://[fe80::a%eth0]/"
         ,false
             ,(HTTP.Offset(1, 4) # UF_SCHEMA
             ,HTTP.Offset(9,12) # UF_HOST
             ,HTTP.Offset(0, 0) # UF_PORT
             ,HTTP.Offset(22, 1) # UF_PATH
             ,HTTP.Offset(0, 0) # UF_QUERY
             ,HTTP.Offset(0, 0) # UF_FRAGMENT
             ,HTTP.Offset(0, 0) # UF_USERINFO
             )
         ,false
         ), URLTest("ipv6 address ending with '%'"
         ,"http://[fe80::a%]/"
         ,false
         ,true # s_dead
         ), URLTest("ipv6 address with Zone ID including bad character"
         ,"http://[fe80::a%\$HOME]/"
         ,false
         ,true # s_dead
         ), URLTest("just ipv6 Zone ID"
         ,"http://[%eth0]/"
         ,false
         ,true # s_dead
         ), URLTest("tab in URL"
         ,"/foo\tbar/"
         ,false
             ,(HTTP.Offset(0, 0) # UF_SCHEMA
             ,HTTP.Offset(0, 0) # UF_HOST
             ,HTTP.Offset(0, 0) # UF_PORT
             ,HTTP.Offset(1, 9) # UF_PATH
             ,HTTP.Offset(0, 0) # UF_QUERY
             ,HTTP.Offset(0, 0) # UF_FRAGMENT
             ,HTTP.Offset(0, 0) # UF_USERINFO
             )
         ,false
         ), URLTest("form feed in URL"
         ,"/foo\fbar/"
         ,false
             ,(HTTP.Offset(0, 0) # UF_SCHEMA
             ,HTTP.Offset(0, 0) # UF_HOST
             ,HTTP.Offset(0, 0) # UF_PORT
             ,HTTP.Offset(1, 9) # UF_PATH
             ,HTTP.Offset(0, 0) # UF_QUERY
             ,HTTP.Offset(0, 0) # UF_FRAGMENT
             ,HTTP.Offset(0, 0) # UF_USERINFO
             )
         ,false
         )
        ]

        for u in urltests
            println("TEST: $(u.name)")
            if u.shouldthrow
                @test_throws HTTP.ParsingError parse(HTTP.URI, u.url; isconnect=u.isconnect)
            else
                url = parse(HTTP.URI, u.url; isconnect=u.isconnect)
                @test u.offsets == url.offsets
            end
        end
    end
end; # @testset
