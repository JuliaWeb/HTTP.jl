module HTTPTLSDistrustTests

using Test
using HTTP
using Reseau

const TLS = Reseau.TLS
const FIXTURES = joinpath(@__DIR__, "resources", "emudhra")

@testset "HTTPS rejects compromised eMudhra CA keys" begin
    mktempdir() do dir
        # Generate an unrelated ephemeral key only to let the local server emit its
        # certificate flight. No eMudhra private key is available or needed: the
        # client must reject the chain before checking the handshake signature.
        key_file = joinpath(dir, "server.key")
        run(`$(TLS.OpenSSL_jll.openssl()) genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out $key_file`)
        for version in (TLS.TLS1_2_VERSION, TLS.TLS1_3_VERSION),
            protocol in (:h1, :h2),
            host in ("dv-g3b-emudhra.we-have-a-problem.com", "dv-g3b-aaa-emudhra.we-have-a-problem.com")
            alpn = protocol == :h2 ? "h2" : "http/1.1"
            listener = TLS.listen("tcp", "127.0.0.1:0", TLS.Config(
                cert_file = joinpath(FIXTURES, host * ".pem"),
                key_file = key_file,
                min_version = version, max_version = version,
                alpn_protocols = [alpn],
            ))
            server_task = errormonitor(Threads.@spawn begin
                conn = nothing
                try
                    conn = TLS.accept(listener)
                    TLS.handshake!(conn)
                catch err
                    # Client rejection is expected; preserve the exception for the
                    # caller rather than logging an unhandled task failure.
                    return err
                finally
                    conn === nothing || close(conn)
                end
                return nothing
            end)
            client = HTTP.Client(transport = HTTP.Transport(proxy = HTTP.ProxyConfig(), tls_config = TLS.Config(
                server_name = host, ca_file = joinpath(FIXTURES, "roots.pem"),
                min_version = version, max_version = version,
                _verification_time_s = Int64(1792497600),
            )))
            try
                port = Int(TLS.addr(listener).port)
                err = try
                    HTTP.get("https://127.0.0.1:$(port)/"; client, protocol,
                        retry = false, redirect = false)
                    nothing
                catch ex
                    ex
                end
                @test err isa HTTP.TLSHandshakeError
                @test occursin("certificate signed by unknown authority", sprint(showerror, err))
                @test !HTTP.isrecoverable(err)
            finally
                close(client)
                close(listener)
                fetch(server_task)
            end
        end
    end
end

end # module
