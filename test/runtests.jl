using HttpCommon
using FactCheck

facts("HttpCommon utility functions") do

    context("Escape HTML") do
        @fact escapeHTML("<script type='text/javascript'>alert('sucker');</script> foo bar") -->
            "&lt;script type='text/javascript'&gt;alert('sucker');&lt;/script&gt; foo bar"
    end

    context("Decode URI") do
        @fact decodeURI("%3Ca+href%3D%27foo%27%3Ebar%3C%2Fa%3Erun%26%2B%2B") -->
            "<a href='foo'>bar</a>run&++"
    end

    context("Encode URI") do
        @fact encodeURI("<a href='foo'>bar</a>run&++") -->
            "%3Ca%20href%3D%27foo%27%3Ebar%3C%2Fa%3Erun%26%2B%2B"
    end

    context("Parse URL query strings") do
        @fact parsequerystring("foo=%3Ca%20href%3D%27foo%27%3Ebar%3C%2Fa%3Erun%26%2B%2B&bar=123") -->
            Dict("foo" => "<a href='foo'>bar</a>run&++", "bar" => "123")
    end

end

# Throw error if any tests fails
FactCheck.exitstatus()