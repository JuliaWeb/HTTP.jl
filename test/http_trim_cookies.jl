include("trim_workload_common.jl")

using Dates

function run_http_trim_cookies()::Nothing
    expires = DateTime(2030, 1, 2, 3, 4, 5)
    cookie = HT.Cookie("session", "a b")
    cookie.path = "/docs;private"
    cookie.domain = ".example.com"
    cookie.expires = expires
    cookie.maxage = 60
    cookie.secure = true
    cookie.httponly = true
    cookie.samesite = HT.SameSiteStrictMode
    expected = "session=\"a b\"; Path=/docsprivate; Domain=example.com; " *
               "Expires=Wed, 02 Jan 2030 03:04:05 GMT; Max-Age=60; " *
               "HttpOnly; Secure; SameSite=Strict"
    HT.stringify(cookie, false) == expected || error("unexpected response cookie")
    HT.stringify(cookie) == "session=\"a b\"" || error("unexpected request cookie")
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_http_trim_cookies()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
