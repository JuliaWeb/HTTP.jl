include("trim_workload_common.jl")

function run_http_trim_open_fileserver()::Nothing
    try
        fixture_dir = joinpath(@__DIR__, "fileserver_fixture")
        handler = HT.fileserver(fixture_dir;
            etag = :weak_stat,
            redirect_canonical = true,
            spa_fallback = "index.html",
        )
        handler isa Function || error("expected fileserver to return a callable handler")

        route_resp = handler(HT.Request("GET", "/gallery"))
        route_resp.status == 200 || error("expected route response status 200")
        chomp(trim_body_string(route_resp.body)) == "<p>shell</p>" || error("unexpected SPA route response body")

        nested_resp = handler(HT.Request("GET", "/gallery/featured"))
        nested_resp.status == 200 || error("expected nested route response status 200")
        chomp(trim_body_string(nested_resp.body)) == "<p>shell</p>" || error("unexpected nested SPA route response body")

        asset_resp = handler(HT.Request("GET", "/assets/app.js"))
        asset_resp.status == 200 || error("expected asset response status 200")
        chomp(trim_body_string(asset_resp.body)) == "console.log('ok');" || error("unexpected asset response body")

        missing_asset = handler(HT.Request("GET", "/assets/missing.js"))
        missing_asset.status == 404 || error("expected missing asset status 404")

        dotted_route = handler(HT.Request("GET", "/gallery.v2"))
        dotted_route.status == 404 || error("expected dotted route status 404")
    finally
        trim_shutdown_runtime()
    end
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_http_trim_open_fileserver()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
