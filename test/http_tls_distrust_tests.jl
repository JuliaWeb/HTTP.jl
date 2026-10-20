module HTTPTLSDistrustTests

using Test
using HTTP
using Reseau

const TLS = Reseau.TLS
const FIXTURES = joinpath(@__DIR__, "resources", "emudhra")

function write_ephemeral_key(path)
    # Julia's bundled OpenSSL_jll exposes libcrypto but not the openssl CLI.
    key = TLS._tls_ec_generate_private_key(TLS.P256)
    bio = Ptr{Cvoid}(C_NULL)
    try
        bio = ccall((:BIO_new_file, TLS._LIBCRYPTO_PATH), Ptr{Cvoid},
            (Cstring, Cstring), path, "w")
        bio == C_NULL && error("could not open temporary key file")
        ok = ccall((:PEM_write_bio_PrivateKey, TLS._LIBCRYPTO_PATH), Cint,
            (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Cint, Ptr{Cvoid}, Ptr{Cvoid}),
            bio, key, C_NULL, C_NULL, 0, C_NULL, C_NULL)
        ok == 1 || error("could not write temporary key")
    finally
        TLS._free_bio!(bio)
        TLS._free_evp_pkey!(key)
    end
    return nothing
end

@testset "HTTPS rejects compromised eMudhra CA keys" begin
    mktempdir() do dir
        # Generate an unrelated ephemeral key only to let the local server emit its
        # certificate flight. No eMudhra private key is available or needed: the
        # client must reject the chain before checking the handshake signature.
        key_file = joinpath(dir, "server.key")
        write_ephemeral_key(key_file)
        for version in (TLS.TLS1_2_VERSION, TLS.TLS1_3_VERSION),
            protocol in (:h1, :h2),
            host in ("dv-g3b-emudhra.we-have-a-problem.com", "dv-g3b-aaa-emudhra.we-have-a-problem.com"),
            request in (HTTP.get, HTTP.head)
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
                    # An accidental retry must fail immediately, rather than
                    # waiting for a second handshake that this server won't serve.
                    close(listener)
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
                url = "https://127.0.0.1:$(port)/"
                method = request === HTTP.get ? "GET" : "HEAD"
                err, output = open(joinpath(dir, "request.log"), "w+") do log
                    err = redirect_stdout(log) do
                        try
                            request(url; client, protocol, retry = true, retries = 1,
                                redirect = false, verbose = true)
                            nothing
                        catch ex
                            ex
                        end
                    end
                    flush(log)
                    seekstart(log)
                    return err, read(log, String)
                end
                @test err isa HTTP.TLSHandshakeError
                @test occursin("certificate signed by unknown authority", sprint(showerror, err))
                @test !HTTP.isrecoverable(err)
                # Health checks and regular requests must both surface the TLS
                # rejection, without retrying or masking its diagnostic.
                @test occursin("[http] request attempt 1 $(method) $(url) via $(protocol)", output)
                @test count("[http] request attempt ", output) == 1
                @test !occursin("[http] retry ", output)
                @test occursin("[http] done with error for $(url):", output)
                @test occursin("certificate signed by unknown authority", output)
            finally
                close(client)
                close(listener)
                fetch(server_task)
            end
        end
    end
end

end # module
