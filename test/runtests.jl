using HttpCommon
using Base.Test

# Headers
@test isa(HttpCommon.headers(), Headers)

# Escape HTML
@test escapeHTML("<script type='text/javascript'>alert('sucker');</script> foo bar") ==
        "&lt;script type=&#39;text/javascript&#39;&gt;alert(&#39;sucker&#39;);&lt;/script&gt; foo bar"

# Parse URL query strings
@test parsequerystring("foo=%3Ca%20href%3D%27foo%27%3Ebar%3C%2Fa%3Erun%26%2B%2B&bar=123") ==
        Dict("foo" => "<a href='foo'>bar</a>run&++", "bar" => "123")
@test parsequerystring("") == Dict()
@test_throws ArgumentError parsequerystring("looknopairs")
@test_throws ArgumentError parsequerystring("good=pair&badpair")