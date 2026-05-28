using Test
using HTTP
using Reseau

const W = HTTP.WebSockets

const _AUTOBAHN_DIR = joinpath(@__DIR__, "websockets")

function _have_docker_autobahn_image()::Bool
    success(`which docker`) || return false
    return success(`docker image inspect crossbario/autobahn-testsuite`)
end

if Int === Int64 && !Sys.iswindows() && get(ENV, "HTTP_RUN_WEBSOCKET_AUTOBAHN", "") == "1"
    _have_docker_autobahn_image() || @warn "Autobahn image not found; skipping websocket interoperability harness"
    if _have_docker_autobahn_image()
        @testset "HTTP.WebSockets Autobahn Server Harness" begin
            server = W.listen!("127.0.0.1", 9002) do ws
                for msg in ws
                    W.send(ws, msg)
                end
            end
            try
                cmd = Cmd(
                    `docker run --rm --add-host=host.docker.internal:host-gateway -v "$_AUTOBAHN_DIR/config:/config" -v "$_AUTOBAHN_DIR/reports:/reports" crossbario/autobahn-testsuite wstest -m fuzzingclient -s /config/fuzzingclient.json`;
                    dir = _AUTOBAHN_DIR,
                )
                @test success(cmd)
            finally
                close(server)
            end
        end
    end
end
