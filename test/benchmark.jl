using Unitful

include("http_parser_benchmark.jl")

using HTTP
using HTTP.IOExtras
using HTTP.Connections
using HTTP.Streams
using HTTP.Messages

responses = [
"github" => """
HTTP/1.1 200 OK\r
Date: Mon, 15 Jan 2018 00:57:33 GMT\r
Content-Type: text/html; charset=utf-8\r
Transfer-Encoding: chunked\r
Server: GitHub.com\r
Status: 200 OK\r
Cache-Control: no-cache\r
Vary: X-PJAX\r
X-UA-Compatible: IE=Edge,chrome=1\r
Set-Cookie: logged_in=no; domain=.github.com; path=/; expires=Fri, 15 Jan 2038 00:57:33 -0000; secure; HttpOnly\r
Set-Cookie: _gh_sess=XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX; path=/; secure; HttpOnly\r
X-Request-Id: fa15328ce7eb90bfe0274b6c97ed4c59\r
X-Runtime: 0.323267\r
Expect-CT: max-age=2592000, report-uri="https://api.github.com/_private/browser/errors"\r
Content-Security-Policy: default-src 'none'; base-uri 'self'; block-all-mixed-content; child-src render.githubusercontent.com; connect-src 'self' uploads.github.com status.github.com collector.githubapp.com api.github.com www.google-analytics.com github-cloud.s3.amazonaws.com github-production-repository-file-5c1aeb.s3.amazonaws.com github-production-upload-manifest-file-7fdce7.s3.amazonaws.com github-production-user-asset-6210df.s3.amazonaws.com wss://live.github.com; font-src assets-cdn.github.com; form-action 'self' github.com gist.github.com; frame-ancestors 'none'; img-src 'self' data: assets-cdn.github.com identicons.github.com collector.githubapp.com github-cloud.s3.amazonaws.com *.githubusercontent.com; media-src 'none'; script-src assets-cdn.github.com; style-src 'unsafe-inline' assets-cdn.github.com\r
Strict-Transport-Security: max-age=31536000; includeSubdomains; preload\r
X-Content-Type-Options: nosniff\r
X-Frame-Options: deny\r
X-XSS-Protection: 1; mode=block\r
X-Runtime-rack: 0.331298\r
Vary: Accept-Encoding\r
X-GitHub-Request-Id: EB38:2597E:1126615:197B74F:5A5BFC7B\r
\r
"""
,
"wikipedia" => """
HTTP/1.1 200 OK\r
Date: Mon, 15 Jan 2018 01:05:05 GMT\r
Content-Type: text/html\r
Content-Length: 74711\r
Connection: keep-alive\r
Server: mw1327.eqiad.wmnet\r
Cache-Control: s-maxage=86400, must-revalidate, max-age=3600\r
ETag: W/"123d7-56241bf703864"\r
Last-Modified: Mon, 08 Jan 2018 11:03:27 GMT\r
Backend-Timing: D=257 t=1515662958810464\r
Vary: Accept-Encoding\r
X-Varnish: 581763780 554073291, 1859700 2056157, 154619657 149630877, 484912801 88058768\r
Via: 1.1 varnish-v4, 1.1 varnish-v4, 1.1 varnish-v4, 1.1 varnish-v4\r
Age: 56146\r
X-Cache: cp1054 hit/10, cp2016 hit/1, cp4029 hit/2, cp4031 hit/345299\r
X-Cache-Status: hit-front\r
Strict-Transport-Security: max-age=106384710; includeSubDomains; preload\r
Set-Cookie: WMF-Last-Access=15-Jan-2018;Path=/;HttpOnly;secure;Expires=Fri, 16 Feb 2018 00:00:00 GMT\r
Set-Cookie: WMF-Last-Access-Global=15-Jan-2018;Path=/;Domain=.wikipedia.org;HttpOnly;secure;Expires=Fri, 16 Feb 2018 00:00:00 GMT\r
X-Analytics: https=1;nocookies=1\r
X-Client-IP: 14.201.217.194\r
Set-Cookie: GeoIP=AU:VIC:Frankston:-38.14:145.12:v4; Path=/; secure; Domain=.wikipedia.org\r
Accept-Ranges: bytes\r
\r
"""
,
"netflix" => """
HTTP/1.1 200 OK\r
Cache-Control: no-cache, no-store, must-revalidate\r
Content-Type: text/html; charset=utf-8\r
Date: Mon, 15 Jan 2018 01:06:12 GMT\r
Expires: 0\r
Pragma: no-cache\r
req_id: 5ee36317-8bbc-448d-88e8-d19a4fb20331\r
Server: shakti-prod i-0a9188462a5e21164\r
Set-Cookie: SecureNetflixId=v%3D2%26mac%3DAQEAEQABABTLdDaklPBpPR3Gwmj9zmjDfOlSLqOftDk.%26dt%3D1515978372532; Domain=.netflix.com; Path=/; Expires=Fri, 01 Jan 2038 00:00:00 GMT; HttpOnly; Secure\r
Set-Cookie: NetflixId=v%3D2%26ct%3DBQAOAAEBEMuUr7yphqTQpaSgxbmFKYeBoN-TtAcb2E5hDcV73R-Qu8VVqjODTPk7URvqrvzZ1bgpPpiS1DlPOn0ePBInOys9GExY-DUnxkMb99H9ogWoz_Ibi3zWJm7tBsizk3NRHdl4dLZJzrrUGy2HC1JJf3k52FBRx-gFf7UyhseihLocdFS579_IQA1xGugB0pAEadI14eeQkjiZadQ0DwHiZJqjxK8QsUX3_MqMFL9O0q2r5oVMO3sq9VLuxSZz3c_XCFPKTvYSCR_sZPCSPp4kQyIkPUzpQLDTC_dEFapTWGKRNnJBtcH6MJXICcB19SXi83lV26gxFRVyd7MVwZUtGvX_jRGkWgZeRXQuS1YHx0GefQF64y7uEwEgGL49fyKLafF9cHH0tGewQm0iPU3NJktKegMzOx1o4j0-HnWRQzDwgiqQqCLy5sqDCGJyxjagvGdQfc0TiHIVvAeuztEP9XPT1IMvydE8F9C7qzVgpwIaVjkrEzSEG4sazqy7xj5y_dTfOeoHPsQEO2IazjiM1SSMPlDK9SEpiQl18B0sR-tNbYGZgRw6KvSJNBSd9KcsfXsf%26bt%3Ddbl%26ch%3DAQEAEAABABTN0reTusSIN2zATnuy-b6hYllVzhgAaq0.%26mac%3DAQEAEAABABRKcEvZN9gx2qYCWw6GyrTFp5r9efkDmFg.; Domain=.netflix.com; Path=/; Expires=Tue, 15 Jan 2019 06:54:58 GMT; HttpOnly\r
Set-Cookie: clSharedContext=f6f2fc4b-427d-4ac1-b21a-45994d6aa3be; Domain=.netflix.com; Path=/\r
Set-Cookie: memclid=73a77399-8bb5-4a12-bdd8-e07f194d6e3d; Max-Age=31536000; Expires=Tue, 15 Jan 2019 01:06:12 GMT; Path=/; Domain=.netflix.com\r
Set-Cookie: nfvdid=BQFmAAEBEFBHN%2BNNVgwjmGFtH09kBA9AsMDpgxuORCUvQF8ZamZmnBCC1dU4zuJausLoGBA%2FqhGfeoY%2FN0%2F6KN9VlAaHaTU%2BLjtMOr8WsF5dSfyQVjJbNg%3D%3D; Max-Age=26265600; Expires=Thu, 15 Nov 2018 01:06:12 GMT; Path=/; Domain=.netflix.com\r
Strict-Transport-Security: max-age=31536000\r
Vary: Accept-Encoding\r
Via: 1.1 i-0842dec9615b5afe9 (us-west-2)\r
X-Content-Type-Options: nosniff\r
X-Frame-Options: DENY\r
X-Netflix-From-Zuul: true\r
X-Netflix.nfstatus: 1_1\r
X-Netflix.proxy.execution-time: 240\r
X-Originating-URL: https://www.netflix.com/au/\r
X-Xss-Protection: 1; mode=block; report=https://ichnaea.netflix.com/log/freeform/xssreport\r
transfer-encoding: chunked\r
Connection: keep-alive\r
\r
"""
,
"twitter" => """
HTTP/1.1 200 OK\r
cache-control: no-cache, no-store, must-revalidate, pre-check=0, post-check=0\r
content-length: 324899\r
content-type: text/html;charset=utf-8\r
date: Mon, 15 Jan 2018 01:08:31 GMT\r
expires: Tue, 31 Mar 1981 05:00:00 GMT\r
last-modified: Mon, 15 Jan 2018 01:08:31 GMT\r
pragma: no-cache\r
server: tsa_l\r
set-cookie: fm=0; Expires=Mon, 15 Jan 2018 01:08:22 UTC; Path=/; Domain=.twitter.com; Secure; HTTPOnly, _twitter_sess=BAh7CSIKZmxhc2hJQzonQWN0aW9uQ29udHJvbGxlcjo6Rmxhc2g6OkZsYXNo%250ASGFzaHsABjoKQHVzZWR7ADoPY3JlYXRlZF9hdGwrCDxUXPdgAToMY3NyZl9p%250AZCIlOGNhY2U5NjdjOWUyYzkwZWIxMGRiZTgyYjI5NDRkNjY6B2lkIiU4NDdl%250AOTIwNGZhN2JhZjg2NTE5ZjY4ZWJhZTEyOGNjNQ%253D%253D--09d63c3cb46541e33a903d83241480ceab65b33e; Path=/; Domain=.twitter.com; Secure; HTTPOnly, personalization_id="v1_7Q083SuV/G6hK5GjmjV/JQ=="; Expires=Wed, 15 Jan 2020 01:08:31 UTC; Path=/; Domain=.twitter.com, guest_id=v1%3A151597851141844671; Expires=Wed, 15 Jan 2020 01:08:31 UTC; Path=/; Domain=.twitter.com, ct0=d81bcd3211730706c80f4b6cb7b793e8; Expires=Mon, 15 Jan 2018 07:08:31 UTC; Path=/; Domain=.twitter.com; Secure\r
status: 200 OK\r
strict-transport-security: max-age=631138519\r
x-connection-hash: 9cc6e603545c8ee9e1895a9c2acddb89\r
x-content-type-options: nosniff\r
x-frame-options: SAMEORIGIN\r
x-response-time: 531\r
x-transaction: 0019e08a0043f702\r
x-twitter-response-tags: BouncerCompliant\r
x-ua-compatible: IE=edge,chrome=1\r
x-xss-protection: 1; mode=block; report=https://twitter.com/i/xss_report\r
\r
"""
,
"akamai" => """
HTTP/1.1 403 Forbidden\r
Server: AkamaiGHost\r
Mime-Version: 1.0\r
Content-Type: text/html\r
Content-Length: 270\r
Expires: Mon, 15 Jan 2018 01:11:29 GMT\r
Date: Mon, 15 Jan 2018 01:11:29 GMT\r
Connection: close\r
Vary: User-Agent\r
\r
"""
,
"nytimes" => """
HTTP/1.1 200 OK\r
Server: Apache\r
Cache-Control: no-cache\r
X-ESI: 1\r
X-App-Response-Time: 0.62\r
Content-Type: text/html; charset=utf-8\r
X-PageType: homepage\r
X-Age: 69\r
X-Origin-Time: 2018-01-14 20:47:16 EDT\r
Content-Length: 213038\r
Accept-Ranges: bytes\r
Date: Mon, 15 Jan 2018 01:13:41 GMT\r
Age: 1585\r
X-Frame-Options: DENY\r
Set-Cookie: vi_www_hp=z00; path=/; domain=.nytimes.com; expires=Wed, 01 Jan 2020 00:00:00 GMT\r
Set-Cookie: vistory=z00; path=/; domain=.nytimes.com; expires=Wed, 01 Jan 2020 00:00:00 GMT\r
Set-Cookie: nyt-a=4HpgpyMVIOWB1wkVLcX98Q; Expires=Tue, 15 Jan 2019 01:13:41 GMT; Path=/; Domain=.nytimes.com\r
Connection: close\r
X-API-Version: F-5-5\r
Content-Security-Policy: default-src data: 'unsafe-inline' 'unsafe-eval' https:; script-src data: 'unsafe-inline' 'unsafe-eval' https: blob:; style-src data: 'unsafe-inline' https:; img-src data: https: blob:; font-src data: https:; connect-src https: wss:; media-src https: blob:; object-src https:; child-src https: data: blob:; form-action https:; block-all-mixed-content;\r
X-Served-By: cache-mel6524-MEL\r
X-Cache: HIT\r
X-Cache-Hits: 2\r
X-Timer: S1515978821.355774,VS0,VE0\r
Vary: Accept-Encoding, Fastly-SSL\r
\r
"""
]

pipeline_limit = 100

randbody(l) = Vector{UInt8}(rand('A':'Z', l))

const tunit = u"μs"
const tmul = Int(1u"s"/1tunit)
delta_t(a, b) = round((b - a) * tmul, digits=0)tunit

fields = [:setup, :head, :body, :close, :joyent_head]

function go(count::Int)

    times = Dict()
    for (name, bytes) in responses
        times[name] = Dict()
        for f in fields
            times[name][f] = []
        end
    end

                                                           t_init_start = time()
    io = Base.BufferStream()
    c = Connection("", "", pipeline_limit, 0, true, io)

                                                            t_init_done = time()
    for rep in 1:count
    gc()
    for (name, bytes) in shuffle(responses)


        write(io, bytes)

        r = Request().response
        readheaders(IOBuffer(bytes), r)
        l = bodylength(r)
        if l == unknown_length
            for i = 1:100
                l = 10000
                chunk = randbody(l)
                write(io, hex(l), "\r\n", chunk, "\r\n")
            end
            write(io, "0\r\n\r\n")
        else
            write(io, randbody(l))
        end

                                                                t_start = time()
        t = Transaction(c)
        r = Request()
        s = Stream(r.response, t)
        #startread(s)
        #function IOExtras.startread(http::Stream)

            http = s
            startread(http.stream)

            # Ensure that the header and body are buffered in the Connection
            # object. Otherwise, the time spent in readheaders below is
            # dominated by readavailable() copying huge body data from the
            # Base.BufferStream. We want to measure the parsing performance.
            unread!(http.stream, readavailable(http.stream))

                                                                t_setup = time()
            HTTP.Streams.readheaders(http.stream, http.message)
                                                         t_headers_done = time()
            HTTP.Streams.handle_continue(http)

            http.readchunked = HTTP.Messages.ischunked(http.message)
            http.ntoread = HTTP.Messages.bodylength(http.message)

        #    return http.message
        #end


        while !eof(s)
            readavailable(s)
        end
                                                            t_body_done = time()
        closeread(s)
                                                                 t_done = time()
        push!(times[name][:setup], delta_t(t_start, t_setup))
        push!(times[name][:head],  delta_t(t_setup, t_headers_done))
        push!(times[name][:body],  delta_t(t_headers_done, t_body_done))
        push!(times[name][:close], delta_t(t_body_done, t_done))

                                                                t_start = time()
        r = HttpParserTest.parse(bytes)
                                                                 t_done = time()
        push!(times[name][:joyent_head], delta_t(t_start, t_done))
    end
    end

    if count <= 10
        return
    end

    w = 12
    print("| ")
    print(lpad("Response",w))
    for f in fields
        print(" | ")
        print(lpad(f,w))
    end
    print(" | ")
    print(lpad("jl faster",w))
    println(" |")

    print("| ")
    print(repeat("-",w))
    for f in [fields..., ""]
        print(":| ")
        print(repeat("-",w))
    end
    println(":|")

    for (name, bytes) in responses
        print("| ")
        print(lpad("$name: ",w))
        for f in fields
            print(" | ")
            print(lpad(mean(times[name][f]), w))
        end
        faster = mean(times[name][:joyent_head]) / mean(times[name][:head])
        print(" | ")
        print(lpad("x $(round(faster, digits=1))", w))
        println(" |")
    end
end

for r in [10, 100]
    go(r)
end
