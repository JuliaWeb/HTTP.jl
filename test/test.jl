using FactCheck
using Calendar
using Httplib

@facts "Httplib utility functions" begin

    @fact "RFC1123 compliant datetimes" begin
        RFC1123_datetime(ymd_hms(2013, 5, 2, 13, 45, 7, "PST")) => 
            "Thu, 02 May 2013 20:45:07 GMT"
    end

    @fact "Escape HTML" begin
        escapeHTML("<script type='text/javascript'>alert('sucker');</script> foo bar") => 
            "&lt;script type='text/javascript'&gt;alert('sucker');&lt;/script&gt; foo bar"
    end

    @fact "Decode URI" begin
        decodeURI("%3Ca+href%3D%27foo%27%3Ebar%3C%2Fa%3Erun%26%2B%2B") =>
            "<a href='foo'>bar</a>run&++"
    end

    @fact "Encode URI" begin
        encodeURI("<a href='foo'>bar</a>run&++") =>
            "%3Ca%20href%3D%27foo%27%3Ebar%3C%2Fa%3Erun%26%2B%2B"
    end

    @fact "Parse URL query strings" begin
        parsequerystring("foo=%3Ca%20href%3D%27foo%27%3Ebar%3C%2Fa%3Erun%26%2B%2B&bar=123") =>
            ["foo" => "<a href='foo'>bar</a>run&++", "bar" => "123"]
    end

    @fact "Sensible response defaults" begin
        res = Response(404)
        res.message => "Not Found"
    end

end