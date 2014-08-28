if VERSION < v"0.4-"
    using Dates
else
    using Base.Dates
end

using FactCheck
using HttpCommon

facts("HttpCommon utility functions") do

    context("RFC1123 compliant datetimes") do
        @fact RFC1123_datetime(DateTime(2013, 5, 2, 13, 45, 7)) =>
            "Thu, 02 May 2013 13:45:07 GMT"
    end

    context("Escape HTML") do
        @fact escapeHTML("<script type='text/javascript'>alert('sucker');</script> foo bar") =>
            "&lt;script type='text/javascript'&gt;alert('sucker');&lt;/script&gt; foo bar"
    end

    context("Decode URI") do
        @fact decodeURI("%3Ca+href%3D%27foo%27%3Ebar%3C%2Fa%3Erun%26%2B%2B") =>
            "<a href='foo'>bar</a>run&++"
    end

    context("Encode URI") do
        @fact encodeURI("<a href='foo'>bar</a>run&++") =>
            "%3Ca%20href%3D%27foo%27%3Ebar%3C%2Fa%3Erun%26%2B%2B"
    end

    context("Parse URL query strings") do
        @fact parsequerystring("foo=%3Ca%20href%3D%27foo%27%3Ebar%3C%2Fa%3Erun%26%2B%2B&bar=123") =>
            ["foo" => "<a href='foo'>bar</a>run&++", "bar" => "123"]
    end

end