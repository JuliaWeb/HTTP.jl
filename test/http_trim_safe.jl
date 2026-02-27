using HTTP

function run_request_response_smoke()::Nothing
    req = HTTP.Request("GET", "/trim"; context=Dict{Symbol, Any}(:trim => true))
    HTTP.setheader(req, "host" => "localhost")
    HTTP.setheader(req, "accept" => "application/json")
    HTTP.issafe(req) || error("expected GET request to be safe")

    resp = HTTP.Response(200, ["content-type" => "application/json"], nothing)
    HTTP.iserror(resp) && error("expected 200 response to be non-error")
    HTTP.getheader(resp, "content-type") == "application/json" || error("unexpected response content-type")

    req.path = "/trim/updated"
    req.path == "/trim/updated" || error("request path mutation failed")
    HTTP.isidempotent(req) || error("GET request should be idempotent")

    redirected = HTTP.Response(302, ["location" => "/next"], nothing)
    HTTP.isredirect(redirected) || error("expected redirect response")
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_request_response_smoke()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
