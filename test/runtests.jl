using HttpCommon
using Base.Test

# Escape HTML
@test escapeHTML("<script type='text/javascript'>alert('sucker');</script> foo bar") ==
        "&lt;script type='text/javascript'&gt;alert('sucker');&lt;/script&gt; foo bar"

# Decode URI
@test decodeURI("%3Ca+href%3D%27foo%27%3Ebar%3C%2Fa%3Erun%26%2B%2B") ==
        "<a href='foo'>bar</a>run&++"

# Encode URI
@test encodeURI("<a href='foo'>bar</a>run&++") ==
        "%3Ca%20href%3D%27foo%27%3Ebar%3C%2Fa%3Erun%26%2B%2B"

# Parse URL query strings
@test parsequerystring("foo=%3Ca%20href%3D%27foo%27%3Ebar%3C%2Fa%3Erun%26%2B%2B&bar=123") ==
        Dict("foo" => "<a href='foo'>bar</a>run&++", "bar" => "123")